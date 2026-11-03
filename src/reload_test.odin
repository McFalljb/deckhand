package main

// Hot reload (reload.odin, ui_reload.odin): the debounce, which tabs a
// change reaches, which are reloaded now and which wait, blockers in the
// confirmation, pi's version and the restart, what is watched
// (`./build.sh test`). Same rules as core_test.odin: shared global State,
// one thread. Sessions are put in State directly; what goes to a bridge is
// captured (reload_send) and its answers played with Bridge_Done.

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
R_UI :: Caller{kind = .UI}

// Sessions (pi tabs running, their bridges reported idle) in /tmp/<name>.
@(private = "file")
r_reset :: proc(names: ..string) -> []u64 {
	context.allocator = runtime.heap_allocator()
	for _, t in terms {
		term_free(t)
		free(t)
	}
	clear(&terms)
	inbox_drain()
	state = State{}
	reload_watch_reset()
	platform = {}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	clear(&r_sends)
	reload_send = proc(tab_id, request_id: u64, cmd: Command) -> bool {
		append(&r_sends, R_Send{tab_id, request_id, cmd})
		return true
	}
	ids := make([]u64, len(names))
	for name, i in names {
		s := Open_Session{id = new_id(), pi_session_id = fmt.aprintf("pi-%s", name), cwd = fmt.aprintf("/tmp/%s", name)}
		append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
		ids[i] = s.tabs[0].id
	}
	if len(names) > 0 do state.current_session = state.open_sessions[0].id
	return ids
}

// What went to bridges (reload_send), instead of a socket.
@(private = "file")
R_Send :: struct {
	tab_id, request_id: u64,
	cmd:                Command,
}
@(private = "file")
r_sends: [dynamic]R_Send

// A running terminal for a pi tab (a harmless process).
@(private = "file")
r_term :: proc(id: u64) -> ^Term {
	t := new(Term)
	term_init(t, 80, 24)
	term_start(t, {"/bin/sh", "-c", "exec sleep 30"}, "/tmp")
	terms[id] = t
	return t
}

@(private = "file")
r_done :: proc() {
	inbox_drain()
	for _, t in terms do reader_stop_and_close(t)
	reload_watch_reset()
	reload_send = socket_bridge_send
	os.unset_env("PI_DESK_PI_PACKAGE")
}

@(private = "file")
r_tab :: proc(id: u64) -> ^Tab {
	_, t, _ := find_tab(id)
	return t
}

@(private = "file")
r_status :: proc(id: u64, agent: Agent_State, waiting := false, blockers: []string = nil) {
	run_command(Pi_Status_Update{tab_id = id, agent = agent, waiting = waiting, blockers = blockers}, {kind = .Panel, tab_id = id})
}

@(private = "file")
r_changed :: proc(path: string, scope := "") {
	run_command(Reload_Watch{paths = {path}, scopes = {scope}})
}

// Changes are reported once none came for RELOAD_DEBOUNCE.
@(test)
reload_debounce :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ids := r_reset("alpha")
	defer r_done()
	t0 := time.tick_now()
	ms :: proc(t0: time.Tick, n: int) -> time.Tick {return time.tick_add(t0, time.Duration(n) * time.Millisecond)}
	reload_pending_add("/x/settings.json", "", t0)
	testing.expect(t, !reload_flush(ms(t0, 500)), "too soon")
	reload_pending_add("/x/extensions/a.ts", "", ms(t0, 800)) // another change: the wait starts again
	reload_pending_add("/x/settings.json", "", ms(t0, 850)) // the same file once
	testing.expect(t, !reload_flush(ms(t0, 1500)), "1 s after the first change, but not after the last")
	testing.expect_value(t, state.reload.gen, u64(0))
	testing.expect(t, reload_flush(ms(t0, 1900)), "quiet for a second")
	testing.expect_value(t, len(state.reload.changed), 2)
	testing.expect(t, r_tab(ids[0]).reload.stale)
	testing.expect(t, !reload_flush(ms(t0, 5000)), "reported once")
	// an editor save: at once
	reload_note_save("/x/keybindings.json", "")
	testing.expect(t, reload_flush(), "a save is not debounced")
	testing.expect(t, state.reload.from_save)
}

// A change reaches the tabs whose pi reads it: everything in the agent dir
// every tab, a folder's files the tabs at or below it, ATLAS.md Atlas.
@(test)
reload_scopes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ids := r_reset("alpha", "beta")
	defer r_done()
	state.open_sessions[1].cwd = "/tmp/alpha/sub"
	home := Open_Session{id = new_id(), home = true, cwd = "/Users/x"}
	append(&home.tabs, Tab{id = new_id(), kind = Pi_Tab{}, status = .Running, agent = .Idle})
	append(&state.open_sessions, home)
	atlas := home.tabs[0].id
	r_changed("/tmp/alpha/sub/AGENTS.md", "/tmp/alpha/sub")
	testing.expect(t, !r_tab(ids[0]).reload.stale && r_tab(ids[1]).reload.stale && !r_tab(atlas).reload.stale, "only the tab below it")
	r_changed("/tmp/AGENTS.md", "/tmp")
	testing.expect(t, r_tab(ids[0]).reload.stale && !r_tab(atlas).reload.stale, "both tabs below /tmp")
	r_changed("/data/atlas/ATLAS.md", RELOAD_SCOPE_ATLAS)
	testing.expect(t, r_tab(atlas).reload.stale, "Atlas's prompt: Atlas")
	r_tab(atlas).reload.stale = false
	r_tab(ids[0]).reload.stale = false
	r_changed("/home/.pi/agent/settings.json")
	testing.expect(t, r_tab(ids[0]).reload.stale && r_tab(atlas).reload.stale, "the agent dir: every pi tab")
	// a tab that is not running is not marked
	r_tab(ids[1]).reload.stale = false
	r_tab(ids[1]).status = .Exited
	r_changed("/home/.pi/agent/models.json")
	testing.expect(t, !r_tab(ids[1]).reload.stale)
}

// Reload: idle tabs now, busy and blocked ones queued (and reloaded once
// idle), tabs without a bridge left out. The user's click asks only when
// background work would wait, and then lists it.
@(test)
reload_idle_and_queued :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ids := r_reset("idle", "busy", "shells", "nobridge")
	defer r_done()
	idle, busy, shells, nob := ids[0], ids[1], ids[2], ids[3]
	r_status(busy, .Working)
	r_status(shells, .Idle, blockers = {"shell sh1: npm test", "subagent review"})
	r_tab(nob).agent = .Unknown
	r_changed("/home/.pi/agent/settings.json")
	n := reload_counts(false)
	testing.expect_value(t, n, Reload_Counts{idle = 1, busy = 2, no_bridge = 1})
	msg, can := reload_message(false)
	testing.expect_value(t, msg, "pi settings changed — Reload 1 idle tab · 2 busy when idle")
	testing.expect(t, can)
	testing.expect(t, reload_bar_shows())

	// the user's click: background work → one confirmation that names it
	r := run_command(Pi_Reload_All{only_changed = true}, R_UI)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, strings.has_prefix(r.confirm_summary, "Reload 3 pi tabs? Background work that a reload would stop: /tmp/shells (shell sh1: npm test; +1). Those tabs wait until it ends."), r.confirm_summary)
	testing.expect(t, r_tab(idle).reload.queued == .None && r_tab(idle).reload.step == .None, "nothing happens before the answer")
	r = run_command(Pi_Reload_All{only_changed = true, confirm = r.confirm_token}, R_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, r.data, fmt.tprintf(`{{"reloading":[%d],"queued":[%d,%d],"no_bridge":[%d]}}`, idle, busy, shells, nob))
	testing.expect_value(t, len(state.pending_confirmations), 0)
	testing.expect(t, r_tab(idle).reload.step == .Reload_Kicked, "the idle one goes (through the inbox)")
	testing.expect(t, r_tab(busy).reload.queued == .Reload && r_tab(shells).reload.queued == .Reload && r_tab(nob).reload.queued == .None)
	testing.expect_value(t, r_tab(shells).reload.note, "waits for shell sh1: npm test")
	msg, can = reload_message(false)
	testing.expect_value(t, msg, "Reloading pi — 2 tabs wait until idle")
	testing.expect(t, !can)

	// the idle tab's bridge gets pi.reload and answers
	inbox_drain()
	testing.expect_value(t, len(r_sends), 1)
	testing.expect(t, r_sends[0].tab_id == idle && r_tab(idle).reload.step == .Reload_Sent)
	run_command(Bridge_Done{request_id = r_sends[0].request_id, ok = true})
	testing.expect(t, !r_tab(idle).reload.stale && r_tab(idle).reload.step == .None)
	testing.expect_value(t, r_tab(idle).reload.note, "reloaded")

	// the busy one goes idle: its reload goes
	r_status(busy, .Idle)
	testing.expect_value(t, r_tab(busy).reload.note, "reloading")
	inbox_drain()
	testing.expect_value(t, len(r_sends), 2)
	// it got busy again before the bridge ran it: again when idle
	run_command(Bridge_Done{request_id = r_sends[1].request_id, ok = false, error = "not idle: agent working"})
	testing.expect(t, r_tab(busy).reload.queued == .Reload && r_tab(busy).reload.stale)
	r_status(busy, .Working)
	testing.expect(t, r_tab(busy).reload.queued == .Reload, "still waiting")
	// the blocked one: its shells end
	r_status(shells, .Idle, blockers = {"shell sh1: npm test"})
	testing.expect(t, r_tab(shells).reload.queued == .Reload, "still blocked")
	r_status(shells, .Idle)
	inbox_drain()
	testing.expect_value(t, len(r_sends), 3)
	run_command(Bridge_Done{request_id = r_sends[2].request_id, ok = true})
	testing.expect(t, !r_tab(shells).reload.stale)

	// Later: the bar hides, the waiting reload is dropped; the next change shows it again
	run_command(Pi_Reload_Later{}, R_UI)
	testing.expect(t, r_tab(busy).reload.queued == .None && !reload_bar_shows())
	r_changed("/home/.pi/agent/extensions/x.ts")
	testing.expect(t, reload_bar_shows())

	// no background work: the click is the decision
	r_status(busy, .Idle)
	r = run_command(Pi_Reload_All{only_changed = true}, R_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, r_tab(busy).reload.step == .Reload_Kicked && r_tab(idle).reload.step == .Reload_Kicked, "both go")
}

// Atlas (control) may reload every pi tab, but the user always confirms,
// whatever its policy; scripts follow theirs; pi tabs may not at all.
@(test)
reload_callers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ids := r_reset("alpha", "beta")
	defer r_done()
	run_command(Set_Confirm_Policy{caller = .Control, class = .Session_Restart, mode = .Auto}, R_UI)
	ctl := Caller{kind = .Control, tab_id = ids[1]} // bound to beta's tab: not its own
	r := run_command(Pi_Reload_All{}, ctl)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, r.confirm_by_user && r.confirm_token == "", "the user confirms, in pi-desk")
	testing.expect_value(t, r.confirm_summary, "A script asks: reload 1 pi tab?") // a control token not bound to Atlas's tab
	run_command(Set_Confirm_Policy{caller = .Script, class = .Session_Restart, mode = .Auto}, R_UI)
	r = run_command(Pi_Reload_All{}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, r_tab(ids[0]).reload.step == .Reload_Kicked && r_tab(ids[1]).reload.step == .Reload_Kicked)
	testing.expect_value(t, run_command(Pi_Reload_All{}, {kind = .Panel, tab_id = ids[0]}).error, "not allowed for this caller")
	testing.expect_value(t, run_command(Pi_Restart_Updated{}, {kind = .Control}).error, "not allowed for this caller")
	testing.expect_value(t, run_command(Pi_Reload_Later{}, {kind = .Control}).error, "not allowed for this caller")
	testing.expect_value(t, run_command(Reload_Watch{}, {kind = .Script}).error, "not allowed for this caller")
	// one pi tab's reload names its background work too
	r_status(ids[0], .Idle, blockers = {"shell sh1: npm test"})
	r = run_command(Pi_Reload{tab_id = ids[0]}, R_UI)
	testing.expect(t, strings.has_suffix(r.confirm_summary, "Background work stops: shell sh1: npm test."), r.confirm_summary)
}

// pi's version on disk: known from its package.json; each tab records the
// one it started with; another version offers a restart of the idle ones,
// which start again on their session file.
@(test)
reload_version_change :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ids := r_reset("alpha", "beta")
	defer r_done()
	dir := fmt.tprintf("%s/pd-reload-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(dir)
	pkg := fmt.tprintf("%s/package.json", dir)
	_ = os.write_entire_file(pkg, transmute([]u8)string(`{"name":"pi","version":"1.0.0"}`))
	os.set_env("PI_DESK_PI_PACKAGE", pkg)
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/agent", dir))
	defer os.unset_env("PI_CODING_AGENT_DIR")
	testing.expect_value(t, pkg_version(pkg), "1.0.0")
	// the first tick: tabs seen, the package read, its version reported at once
	reload_tick()
	testing.expect_value(t, state.reload.pi_version, "1.0.0")
	testing.expect_value(t, r_tab(ids[0]).reload.version, "1.0.0") // seen before the version was known
	testing.expect(t, !restart_bar_shows(), "nothing to restart")
	// pi is updated
	_ = os.write_entire_file(pkg, transmute([]u8)string(`{"name":"pi","version":"1.10.0"}`))
	reload_poll()
	testing.expect(t, reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	testing.expect_value(t, state.reload.pi_version, "1.10.0")
	testing.expect(t, reload_outdated(r_tab(ids[0])) && reload_outdated(r_tab(ids[1])))
	testing.expect(t, restart_bar_shows())
	r_status(ids[1], .Working)
	msg, can := reload_message(true)
	testing.expect_value(t, msg, "pi updated to 1.10.0 — Restart 1 idle tab · 1 busy when idle")
	testing.expect(t, can)
	// a tab started now runs the new one
	s := Open_Session{id = new_id(), cwd = "/tmp/gamma"}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, status = .Running, agent = .Idle})
	append(&state.open_sessions, s)
	reload_tick()
	testing.expect_value(t, r_tab(s.tabs[0].id).reload.version, "1.10.0")
	testing.expect(t, !reload_outdated(r_tab(s.tabs[0].id)))

	// Restart: the idle one is asked through its bridge first (pi.wait_idle,
	// which pi-kit's bridge answers only when pi is truly idle), the busy one queued
	sf := fmt.tprintf("%s/session.jsonl", dir)
	_ = os.write_entire_file(sf, transmute([]u8)string("{}\n"))
	state.open_sessions[0].session_file = strings.clone(sf)
	old := r_term(ids[0])
	old_pid := old.pty.pid
	r := run_command(Pi_Restart_Updated{}, R_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, r.data, fmt.tprintf(`{{"restarting":[%d],"queued":[%d],"no_bridge":[]}}`, ids[0], ids[1]))
	inbox_drain()
	a := r_tab(ids[0])
	testing.expect_value(t, len(r_sends), 1)
	if len(r_sends) == 1 {
		w, is := r_sends[0].cmd.(Pi_Wait_Idle)
		testing.expect(t, is && w.tab_id == ids[0] && w.timeout_ms > 0, "asks the bridge whether pi is idle")
	}
	testing.expect(t, term_of(a.id) == old && a.status == .Running, "nothing killed before the bridge's answer")
	// pi got busy meanwhile: the bridge times out; nothing is killed, it waits for idle
	run_command(Bridge_Done{request_id = r_sends[0].request_id, ok = false, error = "timeout"})
	testing.expect(t, term_of(a.id) == old && a.status == .Running, "not killed")
	testing.expect(t, a.reload.queued == .Restart, "again when idle")
	inbox_drain()
	testing.expect_value(t, len(r_sends), 1) // no second ask by itself
	// idle: asked again; the bridge says idle: the old pi is stopped, the new
	// one starts only once the old process has exited
	r_status(ids[0], .Idle)
	inbox_drain()
	testing.expect_value(t, len(r_sends), 2)
	run_command(Bridge_Done{request_id = r_sends[1].request_id, ok = true})
	testing.expect(t, term_of(a.id) == nil, "the old pi is stopped")
	testing.expect(t, a.status != .Running, "not started while the old process may still run")
	for _ in 0 ..< 300 {
		pty_reap()
		reload_tick()
		if a.status == .Running do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expectf(t, a.status == .Running && term_of(a.id) != nil && term_of(a.id).pty.pid != old_pid, "started again (%v, %v, %q)", a.status, a.reload.step, a.reload.note)
	testing.expect(t, posix.kill(posix.pid_t(old_pid), .NONE) != .OK, "after the old process exited")
	testing.expect(t, a.agent == .Unknown, "its new bridge has not reported yet")
	testing.expect_value(t, a.reload.version, "1.10.0")
	testing.expect_value(t, a.reload.note, "restarted on pi 1.10.0")
	testing.expect(t, r_tab(ids[1]).reload.queued == .Restart)
	// the busy one has no session file to restart from: it says so when it gets idle
	r_status(ids[1], .Idle)
	inbox_drain()
	testing.expect_value(t, r_tab(ids[1]).reload.note, "not restarted: pi has not reported its session file")
	testing.expect(t, r_tab(ids[1]).reload.queued == .None)
	testing.expect_value(t, len(r_sends), 2) // never asked
	// Later hides the bar until the next version
	run_command(Pi_Reload_Later{restart = true}, R_UI)
	testing.expect(t, !restart_bar_shows())
}

// One queue entry is one reload: a kick that already went (or a stray
// one) sends nothing more.
@(test)
reload_double_kick :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ids := r_reset("alpha")
	defer r_done()
	r_changed("/home/.pi/agent/settings.json")
	testing.expect(t, run_command(Pi_Reload_All{only_changed = true}, R_UI).ok)
	// a status report arrives before the inbox runs the kick
	r_status(ids[0], .Idle)
	inbox_drain()
	testing.expect_value(t, len(r_sends), 1)
	if len(r_sends) == 1 {
		_, is := r_sends[0].cmd.(Pi_Reload)
		testing.expect(t, is, "pi.reload")
	}
	// a stray kick, another status: nothing more while the reload runs
	run_command(Reload_Kick{tab_id = ids[0]})
	r_status(ids[0], .Idle)
	inbox_drain()
	testing.expect_value(t, len(r_sends), 1)
	run_command(Bridge_Done{request_id = r_sends[0].request_id, ok = true})
	testing.expect(t, !r_tab(ids[0]).reload.stale)
	run_command(Reload_Kick{tab_id = ids[0]})
	inbox_drain()
	testing.expect_value(t, len(r_sends), 1) // nothing queued: nothing sent
}

// 20k changed paths at once (an npm install, a checkout) stay cheap: at
// most RELOAD_CHANGED_MAX listed, the rest counted, node_modules and .git
// left out, each scope marked once.
@(test)
reload_burst :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset("alpha", "beta")
	defer r_done()
	base := fs_real(fmt.tprintf("%s/pd-reload-burst-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec), context.allocator)
	ad := fmt.tprintf("%s/agent", base)
	os.make_directory_all(fmt.tprintf("%s/extensions", ad))
	os.set_env("PI_CODING_AGENT_DIR", ad)
	defer os.unset_env("PI_CODING_AGENT_DIR")
	reload_build({"/tmp/alpha"})
	paths := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 20_000 do append(&paths, fmt.tprintf("%s/extensions/pkg/src/f%d.ts", ad, i))
	for i in 0 ..< 1000 do append(&paths, fmt.tprintf("%s/extensions/pkg/node_modules/x/f%d.js", ad, i))
	t0 := time.tick_now()
	for p in paths do reload_fs_event(p)
	took_events := time.tick_since(t0)
	t1 := time.tick_now()
	testing.expect(t, reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	took_flush := time.tick_since(t1)
	testing.expectf(t, took_events < 20 * time.Millisecond, "20k events took %v (release builds: about half)", took_events)
	testing.expectf(t, took_flush < 5 * time.Millisecond, "the report took %v", took_flush)
	log.infof("20k FSEvents paths: %v; the report: %v", took_events, took_flush)
	testing.expect_value(t, len(state.reload.changed), RELOAD_CHANGED_MAX)
	testing.expect_value(t, state.reload.changed_more, 20_000 - RELOAD_CHANGED_MAX)
	for p in state.reload.changed do testing.expectf(t, !strings.contains(p, "node_modules"), "listed: %s", p)
	testing.expect(t, state.open_sessions[0].tabs[0].reload.stale && state.open_sessions[1].tabs[0].reload.stale)
	testing.expect_value(t, state.reload.gen, u64(1))
	// only node_modules: nothing to report
	for i in 0 ..< 100 do reload_fs_event(fmt.tprintf("%s/extensions/pkg/node_modules/y/%d.js", ad, i))
	testing.expect(t, !reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
}

// pi itself writes some keys of settings.json in ordinary use (the model
// and thinking level it last used, the changelog it showed, its device
// id): a write that changes only those shows no bar; anything else does.
@(test)
reload_pi_own_settings_keys :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset("alpha")
	defer r_done()
	base := fs_real(fmt.tprintf("%s/pd-reload-keys-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec), context.allocator)
	ad := fmt.tprintf("%s/agent", base)
	os.make_directory_all(ad)
	os.set_env("PI_CODING_AGENT_DIR", ad)
	defer os.unset_env("PI_CODING_AGENT_DIR")
	sp := fmt.tprintf("%s/settings.json", ad)
	w :: proc(p, text: string) {_ = os.write_entire_file(p, transmute([]u8)text)}
	w(sp, `{"theme": "dark", "defaultModel": "a", "lastChangelogVersion": "1.0.0"}`)
	state.open_sessions[0].cwd = base
	reload_poll()
	far := time.tick_add(time.tick_now(), 2 * time.Second)
	testing.expect(t, !reload_flush(far))
	w(sp, `{"lastChangelogVersion": "1.4.0", "theme": "dark", "defaultProvider": "x", "defaultModel": "b", "defaultThinkingLevel": "high", "modelThinkingLevels": {"x/b": "low"}, "deviceId": "d"}`)
	reload_poll()
	testing.expect(t, !reload_flush(far), "only keys pi writes itself")
	w(sp, `{"lastChangelogVersion": "1.4.0", "theme": "light", "defaultModel": "b"}`)
	reload_poll()
	testing.expect(t, reload_flush(far), "the theme changed")
	testing.expect_value(t, state.reload.changed[0], sp)
}

// pi's package is looked for again when the bar would show (pi may have
// moved: another install), not only once.
@(test)
reload_reprobe :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset("alpha")
	defer r_done()
	dir := fmt.tprintf("%s/pd-reload-probe-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(dir)
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/agent", dir))
	defer os.unset_env("PI_CODING_AGENT_DIR")
	a := fmt.tprintf("%s/a.json", dir)
	b := fmt.tprintf("%s/b.json", dir)
	_ = os.write_entire_file(a, transmute([]u8)string(`{"version":"1.0.0"}`))
	_ = os.write_entire_file(b, transmute([]u8)string(`{"version":"2.0.0"}`))
	os.set_env("PI_DESK_PI_PACKAGE", a)
	reload_tick()
	testing.expect_value(t, state.reload.pi_version, "1.0.0")
	os.set_env("PI_DESK_PI_PACKAGE", b) // pi now found elsewhere
	reload_pending_add("/x/settings.json", "")
	testing.expect(t, reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	reload_tick() // takes the new place, reads its version
	testing.expect(t, reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	testing.expect_value(t, state.reload.pi_version, "2.0.0")
}

// What is watched: the agent dir's files and folders (and where its
// symlinks lead), local packages from settings.json, a project's .pi and
// context files up the tree, Atlas's prompt; never credential files, never
// npm packages.
@(test)
reload_sources :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset("x")
	defer r_done()
	base := fs_real(fmt.tprintf("%s/pd-reload-src-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec), context.allocator)
	ad := fmt.tprintf("%s/home/.pi/agent", base)
	kit := fmt.tprintf("%s/kit", base)
	proj := fmt.tprintf("%s/code/proj", base)
	for d in ([]string{fmt.tprintf("%s/extensions", ad), fmt.tprintf("%s/skills", ad), fmt.tprintf("%s/kit/extensions", base), fmt.tprintf("%s/kit/agents", base), fmt.tprintf("%s/.pi/prompts", proj), fmt.tprintf("%s/elsewhere/s1", base)}) do os.make_directory_all(d)
	w :: proc(p, text: string) {_ = os.write_entire_file(p, transmute([]u8)text)}
	w(fmt.tprintf("%s/settings.json", ad), `{"packages":["npm:pi-x@1", {"source":"../../../kit"}, "git:github.com/a/b"], "skills":["-./skip"]}`)
	w(fmt.tprintf("%s/package.json", kit), `{"name":"kit","pi":{"extensions":["./extensions/a/index.ts"],"skills":["./agents"]}}`)
	w(fmt.tprintf("%s/AGENTS.md", ad), "# all\n")
	w(fmt.tprintf("%s/auth.json", ad), "{}")
	w(fmt.tprintf("%s/code/AGENTS.md", base), "# code\n")
	w(fmt.tprintf("%s/.pi/settings.json", proj), `{}`)
	os.symlink(fmt.tprintf("%s/elsewhere/s1", base), fmt.tprintf("%s/skills/s1", ad))
	os.set_env("PI_CODING_AGENT_DIR", ad)
	defer os.unset_env("PI_CODING_AGENT_DIR")
	reload_build({proj})
	src := reload_sources_for_test()
	has :: proc(m: map[string]string, k, scope: string) -> bool {v, ok := m[k]; return ok && v == scope}
	testing.expect(t, has(src, fmt.tprintf("%s/settings.json", ad), ""), "agent settings")
	testing.expect(t, has(src, fmt.tprintf("%s/AGENTS.md", ad), ""), "agent context file")
	testing.expect(t, has(src, fmt.tprintf("%s/extensions/", ad), ""), "agent extensions folder")
	testing.expect(t, has(src, fmt.tprintf("%s/elsewhere/s1/", base), ""), "a skill linked from elsewhere")
	testing.expect(t, has(src, fmt.tprintf("%s/package.json", kit), ""), "a local package")
	testing.expect(t, has(src, fmt.tprintf("%s/extensions/", kit), ""), "its extensions")
	testing.expect(t, has(src, fmt.tprintf("%s/agents/", kit), ""), "a folder its manifest names")
	testing.expect(t, has(src, fmt.tprintf("%s/.pi/settings.json", proj), proj), "the project's settings")
	testing.expect(t, has(src, fmt.tprintf("%s/.pi/prompts/", proj), proj), "the project's prompts")
	testing.expect(t, has(src, fmt.tprintf("%s/code/AGENTS.md", base), fmt.tprintf("%s/code", base)), "a context file above the cwd")
	testing.expect(t, has(src, fmt.tprintf("%s/AGENTS.md", proj), proj), "the cwd's (missing) context file: watched for being made")
	for k, _ in src {
		testing.expectf(t, !strings.contains(k, "auth.json") && !strings.contains(k, "/sessions") && !strings.has_prefix(k, "npm:"), "never watched: %s", k)
	}
	// FSEvents paths: inside a watched folder, credential files left out
	reload_fs_event(fmt.tprintf("%s/extensions/a/index.ts", kit))
	w(fmt.tprintf("%s/extensions/secret.json", ad), "{}")
	os.change_mode(fmt.tprintf("%s/extensions/secret.json", ad), os.perm_number(0o600))
	reload_fs_event(fmt.tprintf("%s/extensions/secret.json", ad))
	reload_fs_event(fmt.tprintf("%s/unrelated.txt", base))
	testing.expect(t, reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	testing.expect_value(t, len(state.reload.changed), 1)
	// the stat poll (built for the running tabs' folders): a context file
	// edited above the cwd reaches the tab
	state.open_sessions[0].cwd = proj
	reload_poll() // builds for proj; stamps as they are
	testing.expect(t, !reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)), "nothing changed yet")
	w(fmt.tprintf("%s/code/AGENTS.md", base), "# code, longer\n")
	reload_poll()
	testing.expect(t, reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	testing.expect(t, slice.contains(state.reload.changed[:], fmt.tprintf("%s/code/AGENTS.md", base)), "listed (with the earlier change: the tab is still stale)")
	testing.expect(t, state.open_sessions[0].tabs[0].reload.stale)
	// a new extension folder in the project: noticed, then watched
	os.make_directory_all(fmt.tprintf("%s/.pi/extensions", proj))
	reload_poll()
	testing.expect(t, reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	reload_poll()
	testing.expect(t, has(reload_sources_for_test(), fmt.tprintf("%s/.pi/extensions/", proj), proj))
	found := false
	for d in reload_watch_dirs() do if d == fmt.tprintf("%s/.pi/extensions", proj) do found = true
	testing.expect(t, found, "handed to FSEvents")
}
