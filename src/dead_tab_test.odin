package main

// A pi tab whose process exited (a "dead tab"): how it ended (exit code or
// signal, from waitpid) on the tab, in its terminal and in the state;
// opening its session again starts pi again in the same tab on the same
// session; pi_restart (the bar's Restart) and Restart with model… (pi's
// model selector once the new pi is up). Same rules as core_test.odin:
// shared global State, one thread (`./build.sh test`).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:time"
import gh "ghostty"

@(private = "file")
D_SCRIPT :: Caller{kind = .Script}
@(private = "file")
D_UI :: Caller{kind = .UI}

@(private = "file")
d_reset :: proc() -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State {
		layout = {left_width = LEFT_WIDTH_DEFAULT, right_width = RIGHT_WIDTH_DEFAULT},
	}
	dead_tab_reset()
	platform = {set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	return runtime.heap_allocator()
}

@(private = "file")
d_done :: proc() {
	inbox_drain()
	for _, t in terms do reader_stop_and_close(t)
	claude_installed_probe = nil
	os.set_env("DECKHAND_CMD", "sleep 30")
}

// One project with one listed session (dddd-1) in a temp HOME's pi store.
@(private = "file")
d_home :: proc() -> (project: u64) {
	home := fmt.aprintf("%s/deckhand-dead-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	dir, _ := filepath.join({home, ".pi", "agent", "sessions", "--tmp--"}, context.temp_allocator)
	os.make_directory_all(dir)
	header := `{"type":"session","version":3,"id":"dddd-1","cwd":"/tmp"}` + "\n"
	_ = os.write_entire_file(fmt.tprintf("%s/2026-10-30T10-00-00-000Z_dddd-1.jsonl", dir), transmute([]u8)header)
	os.set_env("HOME", home)
	rescan_now()
	for p in state.projects do if p.cwd == "/tmp" do return p.id
	return 0
}

// Runs the frame's terminal upkeep until the tab's process is reported gone.
@(private = "file")
d_wait_exit :: proc(tab_id: u64) -> bool {
	for _ in 0 ..< 500 {
		pump_all()
		if _, tab, _ := find_tab(tab_id); tab != nil && tab.status == .Exited do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// A tab's terminal running sh -c `cmd` (in place of its pi).
@(private = "file")
d_term :: proc(tab_id: u64, cmd: string) {
	t := new(Term)
	term_init(t, 80, 24)
	term_start(t, {"/bin/sh", "-c", cmd}, "/tmp")
	terms[tab_id] = t
}

@(private = "file")
d_file_has :: proc(path, want: string) -> bool {
	for _ in 0 ..< 300 {
		data, _ := os.read_entire_file(path, context.temp_allocator)
		if strings.contains(string(data), want) do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(test)
dead_tab_exit_status :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	pid := d_home()
	os.set_env("DECKHAND_CMD", "exit 3")
	r := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_SCRIPT)
	testing.expect(t, r.ok, r.error)
	tab := find_session(r.created_id).tabs[0].id
	testing.expect(t, d_wait_exit(tab), "the tab's process exited")
	_, tb, _ := find_tab(tab)
	testing.expect_value(t, tb.exit, Exit_Info{known = true, code = 3})
	testing.expect_value(t, exit_text(tb.exit), "code 3")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.status"), "exited")
	testing.expect_value(t, json_path(state_json(), "open_sessions.0.tabs.0.exit"), "code 3")
	testing.expect(t, strings.contains(term_screen_text(term_of(tab)), "[process exited: code 3]"), "the terminal says how it ended")
	testing.expect_value(t, dead_tab_tip(tb), "pi exited (code 3)")

	// killed by a signal (a hangup, as when a parent dies): said as one
	os.set_env("DECKHAND_CMD", `kill -HUP $$`)
	r2 := run_command(Pi_Restart{tab_id = tab}, D_SCRIPT)
	testing.expect(t, r2.ok, r2.error)
	testing.expect(t, d_wait_exit(tab), "exited again")
	_, tb, _ = find_tab(tab)
	testing.expect_value(t, tb.exit, Exit_Info{known = true, signal = 1})
	testing.expect_value(t, exit_text(tb.exit), "signal 1 (SIGHUP)")
	testing.expect(t, strings.contains(term_screen_text(term_of(tab)), "[process exited: signal 1 (SIGHUP)]"))
}

@(test)
exit_info_from_wait_status :: proc(t: ^testing.T) {
	testing.expect_value(t, exit_info_from_wait(0), Exit_Info{known = true})
	testing.expect_value(t, exit_info_from_wait(1 << 8), Exit_Info{known = true, code = 1})
	testing.expect_value(t, exit_info_from_wait(127 << 8), Exit_Info{known = true, code = 127})
	testing.expect_value(t, exit_info_from_wait(9), Exit_Info{known = true, signal = 9})
	testing.expect_value(t, exit_info_from_wait(15 | 0x80), Exit_Info{known = true, signal = 15}) // core dumped
	testing.expect_value(t, exit_text({}), "")
	testing.expect_value(t, exit_text({known = true}), "code 0")
	testing.expect_value(t, exit_text({known = true, signal = 11}), "signal 11 (SIGSEGV)")
	testing.expect_value(t, exit_text({known = true, signal = 40}), "signal 40")
	testing.expect(t, !exit_failed({known = true}))
	testing.expect(t, exit_failed({known = true, code = 1}))
	testing.expect(t, exit_failed({known = true, signal = 1}))
	testing.expect(t, exit_failed({}), "unknown: offer everything")
}

// Every way of opening the session again starts pi again in the same tab.
@(test)
dead_tab_open_restarts :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	pid := d_home()
	args := fmt.tprintf("%s/deckhand-dead-args-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	defer os.remove(args)
	os.set_env("DECKHAND_CMD", "exit 1")
	r := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_SCRIPT)
	sess := r.created_id
	tab := find_session(sess).tabs[0].id
	testing.expect(t, d_wait_exit(tab))

	// the listed session's row (and the palette, the bell, open_session)
	os.set_env("DECKHAND_CMD", fmt.tprintf(`printf '%%s\n' "$@" > '%s.tmp'; mv '%s.tmp' '%s'; exec sleep 30`, args, args, args))
	r2 := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_UI)
	testing.expect(t, r2.ok, r2.error)
	testing.expect_value(t, r2.created_id, sess)
	testing.expect_value(t, len(state.open_sessions), 1)
	s := find_session(sess)
	testing.expect_value(t, len(s.tabs), 1)
	testing.expect_value(t, s.tabs[0].id, tab)
	testing.expect_value(t, s.tabs[0].status, Tab_Status.Running)
	testing.expect_value(t, s.tabs[0].exit, Exit_Info{})
	testing.expect(t, term_of(tab) != nil && term_of(tab).running, "a new pi runs")
	testing.expect(t, d_file_has(args, "--session"), "pi resumes the session file")
	testing.expect(t, d_file_has(args, "dddd-1.jsonl"))
	// open while it runs: only focused, nothing restarted
	pid1 := term_of(tab).pty.pid
	run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_UI)
	testing.expect_value(t, term_of(tab).pty.pid, pid1)

	// the Open group's row (a focus that opens): restarts; a plain focus does not
	os.set_env("DECKHAND_CMD", "exit 1")
	run_command(Pi_Restart{tab_id = tab}, D_SCRIPT) // refused: still running
	testing.expect_value(t, term_of(tab).pty.pid, pid1)
	drop_term(tab) // the old pi goes
	d_term(tab, "exit 1")
	testing.expect(t, d_wait_exit(tab))
	os.set_env("DECKHAND_CMD", "sleep 30")
	run_command(Focus_Session{session = sess}, D_UI)
	_, tb, _ := find_tab(tab)
	testing.expect_value(t, tb.status, Tab_Status.Exited)
	run_command(Focus_Session{session = sess, reopen = true}, D_UI)
	_, tb, _ = find_tab(tab)
	testing.expect_value(t, tb.status, Tab_Status.Running)
}

@(test)
pi_restart_command :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	pid := d_home()
	r := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_SCRIPT)
	sess := r.created_id
	tab := find_session(sess).tabs[0].id
	sh := run_command(New_Shell_Tab{session = sess}, D_SCRIPT).created_id

	testing.expect_value(t, run_command(Pi_Restart{tab_id = 999}, D_SCRIPT).error, "no such pi tab")
	testing.expect_value(t, run_command(Pi_Restart{tab_id = sh}, D_SCRIPT).error, "no such pi tab")
	testing.expect_value(t, run_command(Pi_Restart{tab_id = tab}, D_SCRIPT).error, "pi is running in this tab (pi_reload restarts a running one)")

	// JSON both ways
	c, err := parse_command(`{"type":"pi_restart","tab_id":5,"pick_model":true}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.(Pi_Restart), Pi_Restart{tab_id = 5, pick_model = true})
	testing.expect(t, strings.contains(command_json(Pi_Restart{tab_id = 5, pick_model = true}), `"pick_model":true`))
	testing.expect(t, command_spec("pi_restart") != nil, "in the command table")

	// Restart with model…: pi's selector key goes in once the new pi reports
	out := fmt.tprintf("%s/deckhand-dead-keys-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	defer os.remove(out)
	drop_term(tab)
	d_term(tab, "exit 1")
	testing.expect(t, d_wait_exit(tab))
	os.set_env("DECKHAND_CMD", fmt.tprintf("stty raw -echo; exec cat > '%s'", out))
	r2 := run_command(Pi_Restart{tab_id = tab, pick_model = true}, D_UI)
	testing.expect(t, r2.ok, r2.error)
	testing.expect(t, restart_picking(tab), "the selector waits for the new pi")
	dead_tab_tick()
	time.sleep(200 * time.Millisecond)
	data, _ := os.read_entire_file(out, context.temp_allocator)
	testing.expect(t, !strings.contains(string(data), PI_MODEL_SELECT_KEY), "not before pi is up")
	run_command(Pi_Status_Update{tab_id = tab, agent = .Idle}, Caller{kind = .Panel, tab_id = tab})
	dead_tab_tick()
	testing.expect(t, d_file_has(out, PI_MODEL_SELECT_KEY), "the model selector opened")
	testing.expect(t, !restart_picking(tab))

	// a pi that never reports: given up after the wait, said in a toast
	os.set_env("DECKHAND_CMD", "exit 1")
	drop_term(tab)
	d_term(tab, "exit 1")
	_, tb, _ := find_tab(tab)
	tb.agent = .Unknown
	testing.expect(t, d_wait_exit(tab))
	os.set_env("DECKHAND_CMD", "sleep 30")
	run_command(Pi_Restart{tab_id = tab, pick_model = true}, D_UI)
	dead_tab_tick(time.tick_add(time.tick_now(), PICKER_WAIT + time.Second))
	testing.expect(t, !restart_picking(tab))
	testing.expect(t, strings.contains(toast.text, "Ctrl+L"), toast.text)
	testing.expect(t, !strings.contains(toast.text, "desk-bridge"), "no blame on a missing bridge alone")
}

// The bell's entry for a pi that exited, on a session still open: its tab
// shows, and pi starts again (as every other way of opening it).
@(test)
dead_tab_bell_restarts :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	pid := d_home()
	os.set_env("DECKHAND_CMD", "exit 1")
	sess := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_SCRIPT).created_id
	tab := find_session(sess).tabs[0].id
	state.current_session = 0 // not on screen: the exit makes an entry
	testing.expect(t, d_wait_exit(tab))
	testing.expect_value(t, len(state.notices.items), 1)
	os.set_env("DECKHAND_CMD", "sleep 30")
	bell_activate(state.notices.items[0].id)
	inbox_drain()
	_, tb, _ := find_tab(tab)
	testing.expect_value(t, tb.status, Tab_Status.Running)
	testing.expect_value(t, state.current_session, sess)
}

// A restart whose pi cannot start leaves the dead tab as it was (its
// output, how it ended, the bar) and says so.
@(test)
dead_tab_failed_restart_keeps_it :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	pid := d_home()
	os.set_env("DECKHAND_CMD", "exit 4")
	sess := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_SCRIPT).created_id
	tab := find_session(sess).tabs[0].id
	testing.expect(t, d_wait_exit(tab))
	old := term_of(tab)
	os.set_env("SHELL", "/nonexistent/shell") // pty_spawn fails
	defer os.set_env("SHELL", "/bin/sh")
	toast_clear()
	r := run_command(Pi_Restart{tab_id = tab}, D_UI)
	testing.expect(t, !r.ok, "the restart failed")
	_, tb, _ := find_tab(tab)
	testing.expect_value(t, tb.status, Tab_Status.Exited)
	testing.expect_value(t, tb.exit, Exit_Info{known = true, code = 4})
	testing.expect(t, term_of(tab) == old, "its old terminal (and output) stays")
	testing.expect(t, strings.contains(term_screen_text(old), "[process exited: code 4]"))
	testing.expect(t, tab_is_dead(tb), "the bar still shows")
	testing.expect(t, strings.contains(toast.text, "could not start pi"), toast.text)
	// opening it again: the same, and said
	toast_clear()
	run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_UI)
	_, tb, _ = find_tab(tab)
	testing.expect_value(t, tb.status, Tab_Status.Exited)
	testing.expect(t, strings.contains(toast.text, "could not start pi"), toast.text)
}

// pi_restart is for a pi that exited: a restored tab not started yet is
// left alone (and so are its session's other tabs).
@(test)
pi_restart_refuses_not_started :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	s := Open_Session{id = new_id(), pi_session_id = "rrrr-1", cwd = "/tmp", session_file = "/tmp/none.jsonl"}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Not_Started})
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = "shell 1", status = .Not_Started})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	pi, sh := s.tabs[0].id, s.tabs[1].id
	r := run_command(Pi_Restart{tab_id = pi}, D_SCRIPT)
	testing.expect_value(t, r.error, "pi has not started in this tab yet: it starts when its session is shown")
	_, tb, _ := find_tab(pi)
	testing.expect_value(t, tb.status, Tab_Status.Not_Started)
	_, st, _ := find_tab(sh)
	testing.expect_value(t, st.status, Tab_Status.Not_Started)
	testing.expect(t, term_of(pi) == nil && term_of(sh) == nil, "nothing started")
}

// A child whose terminal output ends but that does not exit: hung up on after
// EXIT_REAP_WAIT, how it ended unknown; a restart waits until it is gone
// (SIGKILL after RESTART_EXIT_WAIT), so two pi never share a session file.
@(test)
dead_tab_unknown_exit_waits :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	pid := d_home()
	sess := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_SCRIPT).created_id
	tab := find_session(sess).tabs[0].id
	drop_term(tab)
	// its output ends while it keeps running (macOS keeps a session
	// leader's terminal open, so the end is played: the reader's EOF), and
	// it ignores the hangup
	d_term(tab, "trap '' HUP; exec sleep 30")
	time.sleep(100 * time.Millisecond)
	{
		r := &term_of(tab).reader
		sync.lock(&r.mu)
		r.eof = true
		sync.unlock(&r.mu)
	}
	child := term_of(tab).pty.pid
	start := time.tick_now()
	testing.expect(t, d_wait_exit(tab))
	testing.expect(t, time.tick_since(start) >= EXIT_REAP_WAIT, "waited for it to exit first")
	_, tb, _ := find_tab(tab)
	testing.expect_value(t, tb.exit, Exit_Info{})
	testing.expect(t, exit_failed(tb.exit))
	testing.expect_value(t, dead_tab_tip(tb), "pi exited")
	text := term_screen_text(term_of(tab))
	testing.expect(t, strings.contains(text, "[process exited]"), text)
	pty_reap()
	testing.expect(t, pty_dying(child), "hung up on, still running")

	// a restart now waits for it
	r := run_command(Pi_Restart{tab_id = tab, pick_model = true}, D_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, restart_waiting(tab))
	_, tb, _ = find_tab(tab)
	testing.expect_value(t, tb.status, Tab_Status.Exited)
	testing.expect(t, !tab_is_dead(tb), "no Restart button while it waits")
	testing.expect_value(t, run_command(Pi_Restart{tab_id = tab}, D_UI).error, "this tab is restarting")
	dead_tab_tick()
	testing.expect(t, restart_waiting(tab), "not before the old one is gone")
	// past the wait: SIGKILL, reaped, then pi starts
	dead_tab_tick(time.tick_add(time.tick_now(), RESTART_EXIT_WAIT + time.Second))
	for _ in 0 ..< 200 {
		pty_reap()
		if !pty_dying(child) do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, !pty_dying(child), "killed and reaped")
	dead_tab_tick()
	testing.expect(t, !restart_waiting(tab))
	_, tb, _ = find_tab(tab)
	testing.expect_value(t, tb.status, Tab_Status.Running)
	testing.expect(t, restart_picking(tab), "Restart with model… carried over")
}

// Two "Restart with model…" on different tabs: each gets its selector.
@(test)
dead_tab_pickers_per_tab :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	run_command(Add_Project{cwd = "/tmp"}, D_SCRIPT)
	outs: [2]string
	tabs: [2]u64
	for i in 0 ..< 2 {
		outs[i] = fmt.tprintf("%s/deckhand-dead-pick-%d-%d", os.get_env("TMPDIR", context.temp_allocator), i, time.now()._nsec)
		os.set_env("DECKHAND_CMD", "exit 1")
		sess := run_command(New_Chat{project_id = state.selected_project}, D_SCRIPT).created_id
		tabs[i] = find_session(sess).tabs[0].id
		testing.expect(t, d_wait_exit(tabs[i]))
	}
	defer for o in outs do os.remove(o)
	for i in 0 ..< 2 {
		os.set_env("DECKHAND_CMD", fmt.tprintf("stty raw -echo; exec cat > '%s'", outs[i]))
		testing.expect(t, run_command(Pi_Restart{tab_id = tabs[i], pick_model = true}, D_UI).ok)
	}
	testing.expect(t, restart_picking(tabs[0]) && restart_picking(tabs[1]))
	for i in 0 ..< 2 do run_command(Pi_Status_Update{tab_id = tabs[i], agent = .Idle}, Caller{kind = .Panel, tab_id = tabs[i]})
	dead_tab_tick()
	for i in 0 ..< 2 do testing.expectf(t, d_file_has(outs[i], PI_MODEL_SELECT_KEY), "tab %d got the selector", i)
}

// pi not found (127): said so, and no other model offered.
@(test)
dead_tab_pi_not_found :: proc(t: ^testing.T) {
	tab := Tab{kind = Pi_Tab{}, status = .Exited, exit = {known = true, code = 127}}
	testing.expect(t, !dead_tab_offers_model(&tab))
	testing.expect_value(t, dead_tab_tip(&tab), "pi was not found on your login shell's PATH, in $PI_CODING_AGENT_DIR/bin or in ~/.pi/agent/bin (code 127)")
	tab.exit = {known = true, code = 1}
	testing.expect(t, dead_tab_offers_model(&tab))
	tab.exit = {known = true}
	testing.expect(t, !dead_tab_offers_model(&tab))
}

// A restarted dead pi tab starts with no OSC 7501 status (agent_status.odin).
@(test)
dead_tab_restart_clears_program_status :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	pid := d_home()
	os.set_env("DECKHAND_CMD", "exit 1")
	r := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_SCRIPT)
	tab := find_session(r.created_id).tabs[0].id
	testing.expect(t, d_wait_exit(tab))
	_, tb, _ := find_tab(tab)
	prog_summary_set(&tb.prog, {state = .Error, app = "pi", msg = "boom", records = 1})
	os.set_env("DECKHAND_CMD", "exec sleep 30")
	r2 := run_command(Open_Session_Cmd{project_id = pid, pi_session_id = "dddd-1"}, D_UI)
	testing.expect(t, r2.ok, r2.error)
	_, tb, _ = find_tab(tab)
	testing.expect_value(t, tb.status, Tab_Status.Running)
	testing.expect_value(t, tb.prog.state, Prog_State.None)
	testing.expect_value(t, tab_status_view(tb^).source, Status_Source.None)
}

// ---- a dead Claude tab: Restart with model… ----

// "Restart with model…" on a Claude tab that failed: Claude Code starts again on its conversation
// (--resume), then Deckhand pastes its own fixed `/model` (Claude Code's model picker) under the
// held-prompt rules: only once the turn is idle per the hooks, with bracketed paste on and nothing
// typed; never when claude was not found. Without a ready Claude before the deadline the user is
// told how to open the picker.
@(test)
claude_restart_with_model :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	defer os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
	claude_installed_probe = stand_in_installed // the stand-in claude counts as installed
	dir := fmt.aprintf("%s/deckhand-dead-model-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(dir)
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("pi-dm"), cwd = dir}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	sess := s.id
	os.set_env("DECKHAND_CLAUDE_CMD", "exit 1")
	id := run_command(New_Claude_Tab{session = sess}, D_UI).created_id
	run_command(Claude_Session_Report{tab_id = id, session_id = "0c1a0de0-aaaa-4222-8333-444455556670", source = "startup"}, D_SCRIPT)
	exited := false
	for _ in 0 ..< 500 {
		pump_all()
		if _, tab, _ := find_tab(id); tab != nil && tab.status == .Exited {
			exited = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, exited, "the fake exited")
	_, tab, ct := claude_tab_of(id)
	testing.expect(t, dead_tab_offers_model(tab), "a failed Claude tab offers Restart with model…")
	nf := tab.exit
	tab.exit = {known = true, code = 127}
	testing.expect(t, !dead_tab_offers_model(tab), "not when claude was not found")
	tab.exit = nf
	// restart, then the picker once Claude is ready
	got := fmt.tprintf("%s/claude-stdin", dir)
	os.set_env("DECKHAND_CLAUDE_CMD", fmt.tprintf("exec cat > '%s'", got))
	r := run_command(Claude_Restart{tab_id = id, pick_model = true}, D_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, restart_picking(id), "waits for Claude to be ready")
	read :: proc(p: string) -> string {data, _ := os.read_entire_file(p, context.temp_allocator); return string(data)}
	settle :: proc() {
		for _ in 0 ..< 3 {
			time.sleep(60 * time.Millisecond)
			dead_tab_tick()
			claude_tick()
		}
		time.sleep(120 * time.Millisecond)
	}
	settle()
	testing.expect_value(t, read(got), "") // starting: nothing yet
	run_command(Claude_Turn_Report{tab_id = id, state = "idle"}, D_SCRIPT)
	settle()
	testing.expect_value(t, read(got), "") // no bracketed paste yet
	tm := term_of(id)
	on := "\x1b[?2004h"
	gh.terminal_vt_write(tm.gt, raw_data(on), len(on))
	claude_note_typed(tab)
	settle()
	testing.expect_value(t, read(got), "") // the user is typing
	run_command(Claude_Turn_Report{tab_id = id, state = "submitted"}, D_SCRIPT)
	run_command(Claude_Turn_Report{tab_id = id, state = "idle"}, D_SCRIPT)
	settle()
	testing.expect_value(t, strings.trim_right(read(got), "\r\n"), "\x1b[200~/model\x1b[201~")
	testing.expect(t, !restart_picking(id), "once")
	testing.expect_value(t, ct.turn, Claude_Turn.Working) // the picker is open: nothing else goes in
	// the deadline: never ready, the user is told how
	drop_term(id)
	tab.status, tab.exit = .Exited, Exit_Info{known = true, code = 1}
	os.set_env("DECKHAND_CLAUDE_CMD", "exec sleep 30")
	testing.expect(t, run_command(Claude_Restart{tab_id = id, pick_model = true}, D_UI).ok)
	testing.expect(t, restart_picking(id))
	dead_tab_tick(time.tick_add(time.tick_now(), 60 * time.Second))
	testing.expect(t, !restart_picking(id), "given up")
	// pick_model on the wire
	c, err := parse_command(`{"type":"claude_restart","tab_id":5,"pick_model":true}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.(Claude_Restart), Claude_Restart{tab_id = 5, pick_model = true})
}

// Restart with model… is the user's: an agent's claude_restart with pick_model only restarts.
@(test)
claude_restart_pick_model_user :: proc(t: ^testing.T) {
	context.allocator = d_reset()
	defer d_done()
	defer os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
	claude_installed_probe = stand_in_installed // the stand-in claude counts as installed
	dir := fmt.aprintf("%s/deckhand-dead-pick-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(dir)
	os.set_env("HOME", dir)
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	s := Open_Session{id = new_id(), pi_session_id = strings.clone("pi-dp"), cwd = dir}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	os.set_env("DECKHAND_CLAUDE_CMD", "exit 1")
	id := run_command(New_Claude_Tab{session = s.id}, D_UI).created_id
	run_command(Claude_Session_Report{tab_id = id, session_id = "0c1a0de0-aaaa-4222-8333-444455556690", source = "startup"}, D_SCRIPT)
	exited := false
	for _ in 0 ..< 500 {
		pump_all()
		if _, tab, _ := find_tab(id); tab != nil && tab.status == .Exited {
			exited = true
			break
		}
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, exited, "the fake exited")
	os.set_env("DECKHAND_CLAUDE_CMD", "exec sleep 30")
	r := run_command(Claude_Restart{tab_id = id, pick_model = true}, Caller{kind = .Control})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, !restart_picking(id), "no model picker for an agent's restart")
}
