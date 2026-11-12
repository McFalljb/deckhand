package core

// The bell (notify.odin): which status changes make entries, coalescing,
// bounds, focus marks read, OS notifications, settings and who may send
// the commands (`./build.sh test`). Same rules as core_test.odin: shared
// global State, one thread. No processes: sessions are put in State
// directly.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"

@(private = "file")
N_UI :: Caller{kind = .UI}

@(private = "file")
n_os: [dynamic]string
// Whether the window has the keyboard: what the fake window reports (window_request_test.odin).
@(private = "file")
n_set_active :: proc(on: bool) {fw_facts({active = on})}

// Two open sessions (pi tabs running), the first current; returns their ids.
@(private = "file")
n_reset :: proc() -> (a, b: u64) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	clear(&n_os)
	notice_test_now = time.now()
	platform = {notify = proc(title, body: string) {append(&n_os, fmt.aprintf("%s|%s", title, body))}}
	core_detach_window()
	fw_attach()
	n_set_active(true)
	for name, i in ([]string{"alpha", "beta"}) {
		s := Open_Session{id = new_id(), pi_session_id = fmt.aprintf("pi-%s", name), cwd = fmt.aprintf("/tmp/%s", name)}
		append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle}) // its bridge reported
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
		if i == 0 do a = s.id
		else do b = s.id
	}
	state.current_session = a
	return
}

@(private = "file")
n_tab :: proc(session: u64) -> u64 {return find_session(session).tabs[0].id}

@(private = "file")
n_status :: proc(session: u64, agent: Agent_State, waiting := false, question := false) {
	tab := n_tab(session)
	run_command(Pi_Status_Update{tab_id = tab, agent = agent, waiting = waiting, question = question}, {kind = .Panel, tab_id = tab})
}

@(private = "file")
n_later :: proc(d: time.Duration) {notice_test_now._nsec += i64(d)}

@(private = "file")
n_done :: proc() {
	notice_test_now = {}
	platform = {}
	core_detach_window()
}

@(test)
bell_status_changes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b := n_reset()
	defer n_done()
	// the session on screen: nothing
	n_status(a, .Working)
	n_status(a, .Idle)
	testing.expect_value(t, len(state.notices.items), 0)
	// a background session: finished, then (later) waiting, an error, a question
	n_status(b, .Working)
	n_status(b, .Idle)
	testing.expect_value(t, len(state.notices.items), 1)
	testing.expect_value(t, state.notices.items[0].kind, Notice_Kind.Finished)
	testing.expect_value(t, state.notices.items[0].session, b)
	testing.expect_value(t, state.notices.items[0].title, "Untitled session")
	n_later(11 * time.Second)
	n_status(b, .Idle, waiting = true)
	n_later(11 * time.Second)
	n_status(b, .Error)
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Idle, question = true)
	kinds := [?]Notice_Kind{.Finished, .Waiting, .Error, .Waiting}
	testing.expect_value(t, len(state.notices.items), len(kinds))
	for k, i in kinds do if i < len(state.notices.items) do testing.expect_value(t, state.notices.items[i].kind, k)
	// unknown (the bridge went away) and idle → idle: nothing
	n_status(b, .Idle)
	run_command(Pi_Status_Update{tab_id = n_tab(b), agent = .Unknown})
	testing.expect_value(t, len(state.notices.items), len(kinds))
	// the current session with the window in the background: it counts
	n_set_active(false)
	n_later(11 * time.Second)
	n_status(a, .Working)
	n_status(a, .Idle)
	testing.expect_value(t, state.notices.items[len(state.notices.items) - 1].session, a)
	// pi exited in a background session
	n_set_active(true)
	n_later(11 * time.Second)
	run_command(Tab_Exited{tab_id = n_tab(b)})
	testing.expect_value(t, state.notices.items[len(state.notices.items) - 1].kind, Notice_Kind.Exited)
	testing.expect_value(t, json_path(state_json(), "notifications.unread"), fmt.tprint(len(state.notices.items)))
}

@(test)
bell_coalesces_flapping :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, b := n_reset()
	defer n_done()
	n_set_active(false)
	// within 10 s: one entry, the latest wins; the same kind again raises no second OS notification
	n_status(b, .Working)
	n_status(b, .Error)
	n_later(2 * time.Second)
	n_status(b, .Working)
	n_status(b, .Error)
	n_later(2 * time.Second)
	n_status(b, .Working)
	n_status(b, .Idle, waiting = true)
	testing.expect_value(t, len(state.notices.items), 1)
	testing.expect_value(t, state.notices.items[0].kind, Notice_Kind.Waiting)
	testing.expect_value(t, len(n_os), 1) // one per session per NOTICE_COALESCE
	// past the window: a new entry
	n_later(11 * time.Second)
	n_status(b, .Error)
	testing.expect_value(t, len(state.notices.items), 2)
	// another session's entry does not coalesce with it
	a := state.current_session
	run_command(Focus_Session{session = b}, N_UI)
	n_status(a, .Working)
	n_status(a, .Error)
	testing.expect_value(t, len(state.notices.items), 3)
}

@(test)
bell_bounds :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	n_reset()
	defer n_done()
	for i in 0 ..< NOTICES_MAX + 50 {
		r := run_command(Notify_Post{job = {job_id = fmt.tprintf("job-%d", i), title = strings.repeat("x", 500, context.temp_allocator), status = .Finished}})
		testing.expect(t, r.ok, r.error)
	}
	testing.expect_value(t, len(state.notices.items), NOTICES_MAX)
	testing.expect_value(t, state.notices.items[0].job_id, "job-50") // the oldest went
	testing.expect_value(t, len(state.notices.items[0].title), NOTICE_TEXT_MAX)
	// the list: 20 by default, a limit, at most all
	r := run_command(Notifications_List{}, N_UI)
	testing.expect_value(t, json_path(r.data, "notifications.#"), "20")
	testing.expect_value(t, json_path(r.data, "notifications.0.job_id"), fmt.tprintf("job-%d", NOTICES_MAX + 49))
	r = run_command(Notifications_List{limit = 3}, N_UI)
	testing.expect_value(t, json_path(r.data, "notifications.#"), "3")
	r = run_command(Notifications_List{limit = 100_000}, N_UI)
	testing.expect_value(t, json_path(r.data, "notifications.#"), fmt.tprint(NOTICES_MAX))
	// clear
	run_command(Notifications_Clear{}, N_UI)
	testing.expect_value(t, len(state.notices.items), 0)
}

@(test)
bell_focus_marks_read :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b := n_reset()
	defer n_done()
	n_status(b, .Working)
	n_status(b, .Idle)
	run_command(Notify_Post{job = {job_id = "j1", title = "Backup", status = .Needs_You}})
	testing.expect_value(t, notices_unread(), 2)
	// focusing it while the window is in the background: still unread
	n_set_active(false)
	run_command(Focus_Session{session = b}, N_UI)
	testing.expect_value(t, notices_unread(), 2)
	// the window comes to the front (main.odin: FOCUSED): read
	n_set_active(true)
	run_command(Notifications_Mark_Read{session = state.current_session})
	testing.expect_value(t, notices_unread(), 1)
	// focusing a session while the window is active reads it
	run_command(Focus_Session{session = a}, N_UI)
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Error)
	testing.expect_value(t, notices_unread(), 2)
	r := run_command(Focus_Tab{tab_id = n_tab(b)}, N_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, notices_unread(), 1) // the job's stays
	// one entry, then all
	job := state.notices.items[1].id
	r = run_command(Notifications_Mark_Read{id = job}, N_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, notices_unread(), 0)
	r = run_command(Notifications_Mark_Read{id = 999_999}, N_UI)
	testing.expect(t, !r.ok, "an unknown entry")
	r = run_command(Notifications_Mark_Read{}, N_UI)
	testing.expect(t, !r.ok, "nothing to mark")
	state.notices.items[0].read = false
	run_command(Notifications_Mark_Read{all = true}, N_UI)
	testing.expect_value(t, notices_unread(), 0)
}

@(test)
bell_settings_and_os :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, b := n_reset()
	defer n_done()
	n_set_active(false)
	// defaults: everything collected; waiting, errors, exits, jobs that need you or failed notify
	n_status(b, .Working)
	n_status(b, .Idle)
	testing.expect_value(t, len(n_os), 0) // finished: the bell only
	n_later(11 * time.Second)
	n_status(b, .Idle, waiting = true)
	testing.expect_value(t, len(n_os), 1)
	if len(n_os) == 1 do testing.expect_value(t, n_os[0], "/tmp/beta · Untitled session|Waiting for you")
	for st in Job_Status do run_command(Notify_Post{job = {job_id = fmt.tprintf("j-%v", st), title = "Job", status = st}})
	testing.expect_value(t, len(n_os), 3) // needs you, failed
	testing.expect_value(t, state.notices.os_sent, 3)
	// in front: no OS notification
	n_set_active(true)
	n_later(11 * time.Second)
	n_status(b, .Error)
	testing.expect_value(t, len(n_os), 3)
	// groups off: not collected
	r := run_command(Set_Bell{finished = false, jobs = false}, N_UI)
	testing.expect(t, r.ok, r.error)
	before := len(state.notices.items)
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Idle)
	run_command(Notify_Post{job = {job_id = "j9", title = "Job", status = .Failed}})
	testing.expect_value(t, len(state.notices.items), before)
	testing.expect_value(t, json_path(state_json(), "settings.bell.finished"), "false")
	testing.expect_value(t, json_path(state_json(), "settings.bell.waiting"), "true")
	// OS off
	n_set_active(false)
	run_command(Set_Bell{os = false}, N_UI)
	n_later(11 * time.Second)
	n_status(b, .Error)
	testing.expect_value(t, len(n_os), 3)
	testing.expect_value(t, json_path(state_json(), "settings.bell.os"), "false")
	// saved and read back (persist.odin)
	saved := strings.clone(workspace_json(), context.temp_allocator)
	testing.expect(t, strings.contains(saved, `"bell"`), saved)
	r = run_command(Set_Bell{finished = true, jobs = true, os = true}, N_UI)
	testing.expect_value(t, state.settings.bell_off, bit_set[Bell_Group]{})
	if e := workspace_restore(saved); e != "" do testing.expect(t, false, e)
	testing.expect_value(t, state.settings.bell_off, bit_set[Bell_Group]{.Finished, .Jobs})
	for g in Bell_Group do testing.expectf(t, bell_os_when(state.settings, g) == .Never, "os off restored: %v", g)
}

@(test)
bell_permissions :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, b := n_reset()
	defer n_done()
	n_status(b, .Working)
	n_status(b, .Idle)
	run_command(Notify_Post{job = {job_id = "j1", title = "Nightly", status = .Needs_You, summary = "secret-ish detail", run_dir = "/tmp/run"}})
	control := Caller{kind = .Control}
	panel := Caller{kind = .Panel, tab_id = n_tab(b)}
	script := Caller{kind = .Script}
	// the list: anyone but pi tabs; titles and ids, control without job summaries, never run_dir
	r := run_command(Notifications_List{}, control)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, json_path(r.data, "notifications.#"), "2")
	testing.expect_value(t, json_path(r.data, "notifications.0.kind"), "job")
	testing.expect_value(t, json_path(r.data, "notifications.0.status"), "needs_you")
	testing.expect_value(t, json_path(r.data, "notifications.1.kind"), "finished")
	testing.expect_value(t, json_path(r.data, "notifications.1.session_id"), fmt.tprint(b))
	testing.expect_value(t, json_path(r.data, "notifications.1.read"), "false")
	testing.expect(t, !strings.contains(r.data, "secret-ish") && !strings.contains(r.data, "/tmp/run"), r.data)
	r = run_command(Notifications_List{}, N_UI)
	testing.expect_value(t, json_path(r.data, "notifications.0.summary"), "secret-ish detail")
	testing.expect(t, !run_command(Notifications_List{}, panel).ok, "pi tabs may not list")
	// marking and clearing, settings: the user's
	for c in ([]Caller{control, script, panel}) {
		testing.expect(t, !run_command(Notifications_Mark_Read{all = true}, c).ok, "mark read: user only")
		testing.expect(t, !run_command(Notifications_Clear{}, c).ok, "clear: user only")
		testing.expect(t, !run_command(Set_Bell{os = false}, c).ok, "settings: user only")
		testing.expect(t, !run_command(Notify_Post{job = {job_id = "x", title = "x"}}, c).ok, "notify_post: internal only")
		testing.expect(t, !run_command(Set_Focus{widget = "notifications"}, c).ok, "the popover opens for the user only")
	}
	testing.expect_value(t, notices_unread(), 2)
	// on the wire: notify_post is not a command anyone can send; the others parse
	_, err := parse_command(`{"type":"notify_post","job_id":"x"}`)
	testing.expect(t, err != "", "notify_post is not parsed")
	cmd, perr := parse_command(`{"type":"notifications_list","limit":5}`)
	testing.expect_value(t, perr, "")
	if l, ok := cmd.(Notifications_List); ok do testing.expect_value(t, l.limit, 5)
	cmd, perr = parse_command(`{"type":"set_notifications","jobs":false}`)
	testing.expect_value(t, perr, "")
	if s, ok := cmd.(Set_Bell); ok {
		testing.expect(t, s.jobs != nil && s.finished == nil, "only jobs set")
	}
	// listed for control (pi-kit detects it), not the user-only ones
	lc := list_commands_json(control)
	testing.expect(t, strings.contains(lc, `"notifications_list"`) && !strings.contains(lc, `"notifications_clear"`), lc)
}

// ---- review round 1 ----

// One more open session (pi tab running) with this pi session id; its id.
@(private = "file")
n_add :: proc(pi_session_id: string) -> u64 {
	s := Open_Session{id = new_id(), pi_session_id = strings.clone(pi_session_id), cwd = fmt.aprintf("/tmp/%s", pi_session_id)}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle}) // its bridge reported
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	return s.id
}

// 1. At most one OS notification per session per NOTICE_COALESCE, whatever
// the kind; a burst of 3 or more within NOTICE_BURST becomes one summary.
@(test)
bell_os_not_spammed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, b := n_reset()
	defer n_done()
	n_set_active(false)
	n_status(b, .Idle, waiting = true)
	n_later(2 * time.Second)
	n_status(b, .Error) // another kind, same session, 2 s later: the bell only
	testing.expect_value(t, len(n_os), 1)
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Error)
	testing.expect_value(t, len(n_os), 2)
	// a burst: five sessions need the user within a few seconds
	n_later(11 * time.Second)
	clear(&n_os)
	for i in 0 ..< 5 {
		s := n_add(fmt.tprintf("burst-%d", i))
		n_status(s, .Idle, waiting = true)
		n_later(500 * time.Millisecond)
	}
	testing.expect_value(t, len(state.notices.items) >= 5, true)
	testing.expect_value(t, len(n_os), 3) // two, then one for the rest
	if len(n_os) == 3 do testing.expect(t, strings.contains(n_os[2], "sessions need you"), n_os[2])
	// after the burst: one at a time again
	n_later(11 * time.Second)
	s := n_add("after")
	n_status(s, .Error)
	testing.expect_value(t, len(n_os), 4)
}

// 2. A bridge that reconnects reports its state again: not a change.
@(test)
bell_reconnect_not_a_change :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, b := n_reset()
	defer n_done()
	n_status(b, .Idle, waiting = true)
	testing.expect_value(t, len(state.notices.items), 1)
	n_later(11 * time.Second)
	run_command(Pi_Status_Update{tab_id = n_tab(b), agent = .Unknown}) // the bridge went away
	n_status(b, .Idle, waiting = true) // its reconnect: the same dialog
	n_status(b, .Working) // then real changes: working, error
	n_status(b, .Error)
	testing.expect_value(t, len(state.notices.items), 2)
	if len(state.notices.items) == 2 do testing.expect_value(t, state.notices.items[1].kind, Notice_Kind.Error)
	n_later(11 * time.Second)
	run_command(Pi_Status_Update{tab_id = n_tab(b), agent = .Unknown})
	n_status(b, .Error) // reconnect while still in error
	testing.expect_value(t, len(state.notices.items), 2)
}

// 3. On screen: the current session with its pi tab shown, window in front.
@(test)
bell_on_screen_means_pi_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _ := n_reset()
	defer n_done()
	s := find_session(a)
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, title = "shell 1", status = .Running})
	s.active_tab = s.tabs[1].id // a shell tab of the current session shows
	n_status(a, .Working)
	n_status(a, .Idle)
	testing.expect_value(t, len(state.notices.items), 1)
	run_command(Focus_Session{session = a}, N_UI) // still the shell tab
	testing.expect_value(t, notices_unread(), 1)
	testing.expect(t, !notify_wants_seen(a), "nothing to read while the shell shows")
	r := run_command(Focus_Tab{tab_id = n_tab(a)}, N_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, notices_unread(), 0)
}

// 4. A session closed and opened again: its old entries are read with it.
@(test)
bell_reopened_session_reads :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	_, b := n_reset()
	defer n_done()
	n_status(b, .Working)
	n_status(b, .Idle)
	r := run_command(Close_Session{session = b})
	testing.expect(t, r.ok, r.error)
	c := n_add("pi-beta") // reopened: a new open session, the same pi session
	run_command(Focus_Session{session = c}, N_UI)
	testing.expect_value(t, notices_unread(), 0)
}

// 5. The window coming to the front marks read only when there is something to read.
@(test)
bell_window_focus_only_when_unread :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _ := n_reset()
	defer n_done()
	testing.expect(t, !notify_wants_seen(a), "no entries: nothing to queue")
	n_set_active(false)
	n_status(a, .Working)
	n_status(a, .Idle)
	n_set_active(true)
	testing.expect(t, notify_wants_seen(a), "an unread entry of the session on screen")
	testing.expect(t, !notify_wants_seen(0), "no session")
}

// 6. Quitting: pi processes ending make no entries and no OS notifications.
@(test)
bell_quit_is_quiet :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b := n_reset()
	defer n_done()
	n_set_active(false)
	app_quitting = true
	defer app_quitting = false
	run_command(Tab_Exited{tab_id = n_tab(a)})
	run_command(Tab_Exited{tab_id = n_tab(b)})
	testing.expect_value(t, len(state.notices.items), 0)
	testing.expect_value(t, len(n_os), 0)
}

// What Deckhand could not do for the user (notify_failed: Send to Atlas's
// text left on the clipboard) is said even with the Errors group off: it
// answers the user's own action, and is the only word of where the text went.
@(test)
bell_failed_action_ignores_errors_off :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _ := n_reset()
	defer n_done()
	r := run_command(Set_Bell{errors = false}, N_UI)
	testing.expect(t, r.ok, r.error)
	notify_failed("Send to Atlas", "Atlas waits for you: copied to the clipboard")
	testing.expect_value(t, len(state.notices.items), 1)
	if len(state.notices.items) == 1 do testing.expect_value(t, state.notices.items[0].title, "Atlas waits for you: copied to the clipboard")
	// a session's error is still not collected
	run_command(Tab_Exited{tab_id = n_tab(a)})
	testing.expect_value(t, len(state.notices.items), 1)
	// in the background: the bell entry, but no macOS banner while Errors is off
	n_set_active(false)
	n_later(11 * time.Second)
	notify_failed("Send to Atlas", "pi started over: copied to the clipboard")
	testing.expect_value(t, len(state.notices.items), 2)
	testing.expect_value(t, len(n_os), 0)
	// Errors on: the banner as for any error
	run_command(Set_Bell{errors = true}, N_UI)
	n_later(11 * time.Second)
	notify_failed("Send to Atlas", "pi took too long: copied to the clipboard")
	testing.expect_value(t, len(n_os), 1)
}

// ---- per-group channels and sounds ----

@(private = "file")
n_sounds :: proc() -> (n: int) {
	for op in fw.ops do if op == .Sound do n += 1
	return
}

// Where each kind goes (notice_channels): the defaults in front and behind, then each
// macOS choice and a sound, and a job's finished run never alerts.
@(test)
bell_channels_per_kind :: proc(t: ^testing.T) {
	st: Settings
	Want :: struct {
		bell, os: bool,
		sound:    Bell_Sound,
	}
	// defaults, Deckhand in the background
	behind := [Notice_Kind]Want {
		.Finished      = {true, false, .None},
		.Waiting       = {true, true, .Tink},
		.Error         = {true, true, .None},
		.Exited        = {true, true, .None},
		.Job_Finished  = {true, false, .None},
		.Job_Needs_You = {true, true, .None},
		.Job_Failed    = {true, true, .None},
	}
	for w, k in behind {
		c := notice_channels(st, k, false)
		testing.expectf(t, c.bell == w.bell && c.os == w.os && c.sound == w.sound, "%v behind: %v", k, c)
		// in front: the bell only (macOS background, sounds only behind)
		c = notice_channels(st, k, true)
		testing.expectf(t, c.bell && !c.os && c.sound == .None, "%v in front: %v", k, c)
	}
	// Errors always, with Basso: in front too
	st.bell_os[.Errors], st.bell_sound[.Errors] = .Always, .Basso
	for k in ([]Notice_Kind{.Error, .Exited}) {
		c := notice_channels(st, k, true)
		testing.expectf(t, c.os && c.sound == .Basso, "%v always, in front: %v", k, c)
	}
	// Finished never with Glass: no banner, the sound behind only
	st.bell_sound[.Finished] = .Glass
	c := notice_channels(st, .Finished, false)
	testing.expect(t, !c.os && c.sound == .Glass, "finished: a sound, no banner")
	testing.expect_value(t, notice_channels(st, .Finished, true).sound, Bell_Sound.None)
	// needs you: never, and no sound
	st.bell_os[.Waiting], st.bell_sound[.Waiting] = .Never, .None
	c = notice_channels(st, .Waiting, false)
	testing.expect(t, !c.os && c.sound == .None, "needs you: silenced")
	// Jobs always with Pop: needs you and failed, never a finished run (the job's own notify)
	st.bell_os[.Jobs], st.bell_sound[.Jobs] = .Always, .Pop
	testing.expect(t, notice_channels(st, .Job_Failed, true).os && notice_channels(st, .Job_Failed, true).sound == .Pop, "a failed job, always")
	c = notice_channels(st, .Job_Finished, true)
	testing.expect(t, c.bell && !c.os && c.sound == .None, "a finished job: the bell only")
	// a group off: not collected (and then notice_post drops it before any alert)
	st.bell_off = {.Errors}
	testing.expect(t, !notice_channels(st, .Error, false).bell, "errors off")
	// an older core's one switch off: every group never
	st2: Settings
	st2.bell_os_off = true
	for g in Bell_Group do testing.expect_value(t, bell_os_when(st2, g), Os_When.Never)
}

// The old single switch, saved before per-group settings: off = every group never; on (never
// saved: the default) = today's behaviour. New files keep only what differs from the defaults.
@(test)
bell_settings_migrate :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	n_reset()
	defer n_done()
	base := strings.clone(workspace_json(), context.temp_allocator)
	testing.expect(t, !strings.contains(base, `"bell"`), "defaults: nothing saved")
	old, n := strings.replace(base, `"settings":{`, `"settings":{"bell":{"os":false,"jobs":false},`, 1, context.temp_allocator)
	if !testing.expect_value(t, n, true) do return
	if e := workspace_restore(old); e != "" do testing.expect(t, false, e)
	for g in Bell_Group do testing.expectf(t, bell_os_when(state.settings, g) == .Never, "old os off: %v never", g)
	testing.expect_value(t, bell_sound_of(state.settings, .Waiting), Bell_Sound.Tink) // sounds: the defaults
	testing.expect_value(t, state.settings.bell_off, bit_set[Bell_Group]{.Jobs})
	// saved again in the new form
	saved := strings.clone(workspace_json(), context.temp_allocator)
	testing.expectf(t, strings.contains(saved, `"macos":{`) && !strings.contains(saved, `"os":`), "%s", saved)
	// an old file with the switch on (or none): the defaults, per group as before
	state = State{}
	old2, _ := strings.replace(base, `"settings":{`, `"settings":{"bell":{"os":true},`, 1, context.temp_allocator)
	if e := workspace_restore(old2); e != "" do testing.expect(t, false, e)
	testing.expect_value(t, state.settings.bell_os, [Bell_Group]Os_When{})
	for g in Bell_Group do testing.expect_value(t, bell_os_when(state.settings, g), BELL_OS_DEFAULT[g])
	// a choice equal to the default is kept as Default; others round-trip
	run_command(Set_Bell{macos = #partial [Bell_Group]Maybe(Os_When){.Finished = .Always, .Waiting = .Background}, sound = #partial [Bell_Group]Maybe(Bell_Sound){.Errors = .Basso, .Waiting = .Glass}}, N_UI)
	testing.expect_value(t, state.settings.bell_os[.Waiting], Os_When.Default)
	saved = strings.clone(workspace_json(), context.temp_allocator)
	state = State{}
	if e := workspace_restore(saved); e != "" do testing.expect(t, false, e)
	testing.expect_value(t, bell_os_when(state.settings, .Finished), Os_When.Always)
	testing.expect_value(t, bell_sound_of(state.settings, .Errors), Bell_Sound.Basso)
	testing.expect_value(t, bell_sound_of(state.settings, .Waiting), Bell_Sound.Glass)
	testing.expect_value(t, json_path(state_json(), "settings.bell.macos.finished"), "always")
	testing.expect_value(t, json_path(state_json(), "settings.bell.sound.waiting"), "glass")
	// on the wire: set_notifications parses and writes the groups back the same
	cmd, err := parse_command(`{"type":"set_notifications","macos":{"jobs":"never","finished":"default"},"sound":{"waiting":"none"}}`)
	testing.expect_value(t, err, "")
	sb, _ := cmd.(Set_Bell)
	testing.expect(t, sb.macos[.Jobs] == Os_When.Never && sb.macos[.Finished] == Os_When.Default && sb.macos[.Waiting] == nil, "macos parsed")
	testing.expect(t, sb.sound[.Waiting] == Bell_Sound.None && sb.sound[.Jobs] == nil, "sound parsed")
	b := strings.builder_make(context.temp_allocator)
	notify_write(&b, sb)
	again, aerr := parse_command(fmt.tprintf(`{{"type":"set_notifications"%s}}`, strings.to_string(b)))
	testing.expect_value(t, aerr, "")
	testing.expect_value(t, again.(Set_Bell), sb)
	for bad in ([]string{`{"type":"set_notifications","sound":{"waiting":"Submarine"}}`, `{"type":"set_notifications","macos":{"nope":"never"}}`, `{"type":"set_notifications","macos":"never"}`}) {
		_, e := parse_command(bad)
		testing.expectf(t, e != "", "refused: %s", bad)
	}
}

// A sound goes to the window once per entry that alerts, paced with the macOS notifications,
// never twice within SOUND_FLOOR, never to a hub, and not while Deckhand is in front.
@(test)
bell_sounds :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b := n_reset()
	defer n_done()
	// in front: needs you is quiet by default
	n_status(b, .Idle, waiting = true)
	testing.expect_value(t, n_sounds(), 0)
	// behind: Tink, once; a finished run none
	n_set_active(false)
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Idle, waiting = true)
	testing.expect_value(t, n_sounds(), 1)
	testing.expect_value(t, fw.last.text, "Tink")
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Idle)
	testing.expect_value(t, n_sounds(), 1)
	// the floor: another session within a second rings its banner, not a second sound
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Idle, waiting = true)
	n_later(500 * time.Millisecond)
	n_status(a, .Working)
	n_status(a, .Idle, waiting = true)
	testing.expect_value(t, n_sounds(), 2)
	testing.expect_value(t, state.notices.sounds, 2)
	testing.expect(t, !sound_floor_ok(notice_now(), time.time_add(notice_now(), 999 * time.Millisecond)), "within the floor")
	testing.expect(t, sound_floor_ok(notice_now(), time.time_add(notice_now(), time.Second)), "past it")
	testing.expect(t, sound_floor_ok({}, notice_now()), "none yet")
	// macOS never: the sound still plays behind (no banner)
	run_command(Set_Bell{macos = #partial [Bell_Group]Maybe(Os_When){.Waiting = .Never}}, N_UI)
	os_before := len(n_os)
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Idle, waiting = true)
	testing.expect_value(t, n_sounds(), 3)
	testing.expect_value(t, len(n_os), os_before)
	// always: in front too
	run_command(Set_Bell{macos = #partial [Bell_Group]Maybe(Os_When){.Waiting = .Always}}, N_UI)
	n_set_active(true)
	run_command(Focus_Session{session = a}, N_UI)
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Idle, waiting = true)
	testing.expect_value(t, n_sounds(), 4)
	testing.expect_value(t, len(n_os), os_before + 1)
	// another machine's entry: the same rules
	n_later(11 * time.Second)
	notify_remote(Notice{kind = .Waiting, machine = 7, title = strings.clone("t"), place = strings.clone("nuc")})
	testing.expect_value(t, n_sounds(), 5)
	// none: silent
	run_command(Set_Bell{sound = #partial [Bell_Group]Maybe(Bell_Sound){.Waiting = .None}}, N_UI)
	n_later(11 * time.Second)
	n_status(b, .Working)
	n_status(b, .Idle, waiting = true)
	testing.expect_value(t, n_sounds(), 5)
}

// Nobody but this Mac's user changes the sounds or the macOS choices: not an agent (control), a
// pi tab, a script, nor another machine (a hub's ui).
@(test)
bell_sound_settings_user_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	n_reset()
	defer n_done()
	for c in ([]Caller{{kind = .Control}, {kind = .Script}, {kind = .Panel, tab_id = 1}, {kind = .UI, hub = true}, {kind = .Control, hub = true}}) {
		r := run_command(Set_Bell{sound = #partial [Bell_Group]Maybe(Bell_Sound){.Finished = .Hero}, macos = #partial [Bell_Group]Maybe(Os_When){.Finished = .Always}}, c)
		testing.expectf(t, !r.ok, "%v may not set sounds", c)
	}
	testing.expect_value(t, state.settings.bell_sound, [Bell_Group]Bell_Sound{})
	testing.expect_value(t, state.settings.bell_os, [Bell_Group]Os_When{})
	testing.expect(t, run_command(Set_Bell{sound = #partial [Bell_Group]Maybe(Bell_Sound){.Finished = .Hero}}, N_UI).ok, "the user's")
	testing.expect_value(t, bell_sound_of(state.settings, .Finished), Bell_Sound.Hero)
}
