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
import "core"

@(private = "file")
R_UI :: core.Caller{kind = .UI}

// Sessions (pi tabs running, their bridges reported idle) in /tmp/<name>.
@(private = "file")
r_reset :: proc(names: ..string) -> []u64 {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	state^ = core.State{}
	core.reload_watch_reset()
	core.platform = {}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	clear(&r_sends)
	core.reload_send = proc(tab_id, request_id: u64, cmd: core.Command) -> bool {
		append(&r_sends, R_Send{tab_id, request_id, cmd})
		return true
	}
	ids := make([]u64, len(names))
	for name, i in names {
		s := core.Open_Session{id = core.new_id(), pi_session_id = fmt.aprintf("pi-%s", name), cwd = fmt.aprintf("/tmp/%s", name)}
		append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
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
	cmd:                core.Command,
}
@(private = "file")
r_sends: [dynamic]R_Send

// A running terminal for a pi tab (a harmless process).
@(private = "file")
r_term :: proc(id: u64) -> ^core.Term {
	t := new(core.Term)
	core.term_init(t, 80, 24)
	core.term_start(t, {"/bin/sh", "-c", "exec sleep 30"}, "/tmp")
	core.terms[id] = t
	return t
}

@(private = "file")
r_done :: proc() {
	core.inbox_drain()
	for _, t in core.terms do core.reader_stop_and_close(t)
	core.reload_watch_reset()
	core.reload_send = core.socket_bridge_send
	os.unset_env("DECKHAND_PI_PACKAGE")
}

@(private = "file")
r_tab :: proc(id: u64) -> ^core.Tab {
	_, t, _ := core.find_tab(id)
	return t
}

@(private = "file")
r_status :: proc(id: u64, agent: core.Agent_State, waiting := false, blockers: []string = nil) {
	core.run_command(core.Pi_Status_Update{tab_id = id, agent = agent, waiting = waiting, blockers = blockers}, {kind = .Panel, tab_id = id})
}

@(private = "file")
r_changed :: proc(path: string, scope := "") {
	core.run_command(core.Reload_Watch{paths = {path}, scopes = {scope}})
}

// Changes are reported once none came for RELOAD_DEBOUNCE.
@(test)
reload_debounce :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	ids := r_reset("alpha")
	defer r_done()
	t0 := time.tick_now()
	ms :: proc(t0: time.Tick, n: int) -> time.Tick {return time.tick_add(t0, time.Duration(n) * time.Millisecond)}
	core.reload_pending_add("/x/settings.json", "", t0)
	testing.expect(t, !core.reload_flush(ms(t0, 500)), "too soon")
	core.reload_pending_add("/x/extensions/a.ts", "", ms(t0, 800)) // another change: the wait starts again
	core.reload_pending_add("/x/settings.json", "", ms(t0, 850)) // the same file once
	testing.expect(t, !core.reload_flush(ms(t0, 1500)), "1 s after the first change, but not after the last")
	testing.expect_value(t, state.reload.gen, u64(0))
	testing.expect(t, core.reload_flush(ms(t0, 1900)), "quiet for a second")
	testing.expect_value(t, len(state.reload.changed), 2)
	testing.expect(t, r_tab(ids[0]).reload.stale)
	testing.expect(t, !core.reload_flush(ms(t0, 5000)), "reported once")
	// an editor save: at once
	core.reload_note_save("/x/keybindings.json", "")
	testing.expect(t, core.reload_flush(), "a save is not debounced")
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
	home := core.Open_Session{id = core.new_id(), home = true, cwd = "/Users/x"}
	append(&home.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, status = .Running, agent = .Idle})
	append(&state.open_sessions, home)
	atlas := home.tabs[0].id
	r_changed("/tmp/alpha/sub/AGENTS.md", "/tmp/alpha/sub")
	testing.expect(t, !r_tab(ids[0]).reload.stale && r_tab(ids[1]).reload.stale && !r_tab(atlas).reload.stale, "only the tab below it")
	r_changed("/tmp/AGENTS.md", "/tmp")
	testing.expect(t, r_tab(ids[0]).reload.stale && !r_tab(atlas).reload.stale, "both tabs below /tmp")
	r_changed("/data/atlas/ATLAS.md", core.RELOAD_SCOPE_ATLAS)
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
	r := core.run_command(core.Pi_Reload_All{only_changed = true}, R_UI)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, strings.has_prefix(r.confirm_summary, "Reload 3 pi tabs? Background work that a reload would stop: /tmp/shells (shell sh1: npm test; +1). Those tabs wait until it ends."), r.confirm_summary)
	testing.expect(t, r_tab(idle).reload.queued == .None && r_tab(idle).reload.step == .None, "nothing happens before the answer")
	r = core.run_command(core.Pi_Reload_All{only_changed = true, confirm = r.confirm_token}, R_UI)
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
	core.inbox_drain()
	testing.expect_value(t, len(r_sends), 1)
	testing.expect(t, r_sends[0].tab_id == idle && r_tab(idle).reload.step == .Reload_Sent)
	core.run_command(core.Bridge_Done{request_id = r_sends[0].request_id, ok = true})
	testing.expect(t, !r_tab(idle).reload.stale && r_tab(idle).reload.step == .None)
	testing.expect_value(t, r_tab(idle).reload.note, "reloaded")

	// the busy one goes idle: its reload goes
	r_status(busy, .Idle)
	testing.expect_value(t, r_tab(busy).reload.note, "reloading")
	core.inbox_drain()
	testing.expect_value(t, len(r_sends), 2)
	// it got busy again before the bridge ran it: again when idle
	core.run_command(core.Bridge_Done{request_id = r_sends[1].request_id, ok = false, error = "not idle: agent working"})
	testing.expect(t, r_tab(busy).reload.queued == .Reload && r_tab(busy).reload.stale)
	r_status(busy, .Working)
	testing.expect(t, r_tab(busy).reload.queued == .Reload, "still waiting")
	// the blocked one: its shells end
	r_status(shells, .Idle, blockers = {"shell sh1: npm test"})
	testing.expect(t, r_tab(shells).reload.queued == .Reload, "still blocked")
	r_status(shells, .Idle)
	core.inbox_drain()
	testing.expect_value(t, len(r_sends), 3)
	core.run_command(core.Bridge_Done{request_id = r_sends[2].request_id, ok = true})
	testing.expect(t, !r_tab(shells).reload.stale)

	// Later: the bar hides, the waiting reload is dropped; the next change shows it again
	core.run_command(core.Pi_Reload_Later{}, R_UI)
	testing.expect(t, r_tab(busy).reload.queued == .None && !reload_bar_shows())
	r_changed("/home/.pi/agent/extensions/x.ts")
	testing.expect(t, reload_bar_shows())

	// no background work: the click is the decision
	r_status(busy, .Idle)
	r = core.run_command(core.Pi_Reload_All{only_changed = true}, R_UI)
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
	core.run_command(core.Set_Confirm_Policy{caller = .Control, class = .Session_Restart, mode = .Auto}, R_UI)
	ctl := core.Caller{kind = .Control, tab_id = ids[1]} // bound to beta's tab: not its own
	r := core.run_command(core.Pi_Reload_All{}, ctl)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, r.confirm_by_user && r.confirm_token == "", "the user confirms, in Deckhand")
	testing.expect_value(t, r.confirm_summary, "A script asks: reload 1 pi tab?") // a control token not bound to Atlas's tab
	core.run_command(core.Set_Confirm_Policy{caller = .Script, class = .Session_Restart, mode = .Auto}, R_UI)
	r = core.run_command(core.Pi_Reload_All{}, {kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect(t, r_tab(ids[0]).reload.step == .Reload_Kicked && r_tab(ids[1]).reload.step == .Reload_Kicked)
	testing.expect_value(t, core.run_command(core.Pi_Reload_All{}, {kind = .Panel, tab_id = ids[0]}).error, "not allowed for this caller")
	testing.expect_value(t, core.run_command(core.Pi_Restart_Updated{}, {kind = .Control}).error, "not allowed for this caller")
	testing.expect_value(t, core.run_command(core.Pi_Reload_Later{}, {kind = .Control}).error, "not allowed for this caller")
	testing.expect_value(t, core.run_command(core.Reload_Watch{}, {kind = .Script}).error, "not allowed for this caller")
	// one pi tab's reload names its background work too
	r_status(ids[0], .Idle, blockers = {"shell sh1: npm test"})
	r = core.run_command(core.Pi_Reload{tab_id = ids[0]}, R_UI)
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
	os.set_env("DECKHAND_PI_PACKAGE", pkg)
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/agent", dir))
	defer os.unset_env("PI_CODING_AGENT_DIR")
	testing.expect_value(t, core.pkg_version(pkg), "1.0.0")
	// the first tick: tabs seen, the package read, its version reported at once
	core.reload_tick()
	testing.expect_value(t, state.reload.pi_version, "1.0.0")
	testing.expect_value(t, r_tab(ids[0]).reload.version, "1.0.0") // seen before the version was known
	testing.expect(t, !restart_bar_shows(), "nothing to restart")
	// pi is updated
	_ = os.write_entire_file(pkg, transmute([]u8)string(`{"name":"pi","version":"1.10.0"}`))
	core.reload_poll()
	testing.expect(t, core.reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	testing.expect_value(t, state.reload.pi_version, "1.10.0")
	testing.expect(t, core.reload_outdated(r_tab(ids[0])) && core.reload_outdated(r_tab(ids[1])))
	testing.expect(t, restart_bar_shows())
	r_status(ids[1], .Working)
	msg, can := reload_message(true)
	testing.expect_value(t, msg, "pi updated to 1.10.0 — Restart 1 idle tab · 1 busy when idle")
	testing.expect(t, can)
	// a tab started now runs the new one
	s := core.Open_Session{id = core.new_id(), cwd = "/tmp/gamma"}
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, status = .Running, agent = .Idle})
	append(&state.open_sessions, s)
	core.reload_tick()
	testing.expect_value(t, r_tab(s.tabs[0].id).reload.version, "1.10.0")
	testing.expect(t, !core.reload_outdated(r_tab(s.tabs[0].id)))

	// Restart: the idle one is asked through its bridge first (pi.wait_idle,
	// which pi-kit's bridge answers only when pi is truly idle), the busy one queued
	sf := fmt.tprintf("%s/session.jsonl", dir)
	_ = os.write_entire_file(sf, transmute([]u8)string("{}\n"))
	state.open_sessions[0].session_file = strings.clone(sf)
	old := r_term(ids[0])
	old_pid := old.pty.pid
	r := core.run_command(core.Pi_Restart_Updated{}, R_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, r.data, fmt.tprintf(`{{"restarting":[%d],"queued":[%d],"no_bridge":[]}}`, ids[0], ids[1]))
	core.inbox_drain()
	a := r_tab(ids[0])
	testing.expect_value(t, len(r_sends), 1)
	if len(r_sends) == 1 {
		w, is := r_sends[0].cmd.(core.Pi_Wait_Idle)
		testing.expect(t, is && w.tab_id == ids[0] && w.timeout_ms > 0, "asks the bridge whether pi is idle")
	}
	testing.expect(t, core.term_of(a.id) == old && a.status == .Running, "nothing killed before the bridge's answer")
	// pi got busy meanwhile: the bridge times out; nothing is killed, it waits for idle
	core.run_command(core.Bridge_Done{request_id = r_sends[0].request_id, ok = false, error = "timeout"})
	testing.expect(t, core.term_of(a.id) == old && a.status == .Running, "not killed")
	testing.expect(t, a.reload.queued == .Restart, "again when idle")
	core.inbox_drain()
	testing.expect_value(t, len(r_sends), 1) // no second ask by itself
	// idle: asked again; the bridge says idle: the old pi is stopped, the new
	// one starts only once the old process has exited
	r_status(ids[0], .Idle)
	core.inbox_drain()
	testing.expect_value(t, len(r_sends), 2)
	core.run_command(core.Bridge_Done{request_id = r_sends[1].request_id, ok = true})
	testing.expect(t, core.term_of(a.id) == nil, "the old pi is stopped")
	testing.expect(t, a.status != .Running, "not started while the old process may still run")
	for _ in 0 ..< 300 {
		core.pty_reap()
		core.reload_tick()
		if a.status == .Running do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expectf(t, a.status == .Running && core.term_of(a.id) != nil && core.term_of(a.id).pty.pid != old_pid, "started again (%v, %v, %q)", a.status, a.reload.step, a.reload.note)
	testing.expect(t, posix.kill(posix.pid_t(old_pid), .NONE) != .OK, "after the old process exited")
	testing.expect(t, a.agent == .Unknown, "its new bridge has not reported yet")
	testing.expect_value(t, a.reload.version, "1.10.0")
	testing.expect_value(t, a.reload.note, "restarted on pi 1.10.0")
	testing.expect(t, r_tab(ids[1]).reload.queued == .Restart)
	// the busy one has no session file to restart from: it says so when it gets idle
	r_status(ids[1], .Idle)
	core.inbox_drain()
	testing.expect_value(t, r_tab(ids[1]).reload.note, "not restarted: pi has not reported its session file")
	testing.expect(t, r_tab(ids[1]).reload.queued == .None)
	testing.expect_value(t, len(r_sends), 2) // never asked
	// Later hides the bar until the next version
	core.run_command(core.Pi_Reload_Later{restart = true}, R_UI)
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
	testing.expect(t, core.run_command(core.Pi_Reload_All{only_changed = true}, R_UI).ok)
	// a status report arrives before the inbox runs the kick
	r_status(ids[0], .Idle)
	core.inbox_drain()
	testing.expect_value(t, len(r_sends), 1)
	if len(r_sends) == 1 {
		_, is := r_sends[0].cmd.(core.Pi_Reload)
		testing.expect(t, is, "pi.reload")
	}
	// a stray kick, another status: nothing more while the reload runs
	core.run_command(core.Reload_Kick{tab_id = ids[0]})
	r_status(ids[0], .Idle)
	core.inbox_drain()
	testing.expect_value(t, len(r_sends), 1)
	core.run_command(core.Bridge_Done{request_id = r_sends[0].request_id, ok = true})
	testing.expect(t, !r_tab(ids[0]).reload.stale)
	core.run_command(core.Reload_Kick{tab_id = ids[0]})
	core.inbox_drain()
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
	base := core.fs_real(fmt.tprintf("%s/pd-reload-burst-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec), context.allocator)
	ad := fmt.tprintf("%s/agent", base)
	os.make_directory_all(fmt.tprintf("%s/extensions", ad))
	os.set_env("PI_CODING_AGENT_DIR", ad)
	defer os.unset_env("PI_CODING_AGENT_DIR")
	core.reload_build({"/tmp/alpha"})
	paths := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< 20_000 do append(&paths, fmt.tprintf("%s/extensions/pkg/src/f%d.ts", ad, i))
	for i in 0 ..< 1000 do append(&paths, fmt.tprintf("%s/extensions/pkg/node_modules/x/f%d.js", ad, i))
	// CPU time (this thread's): a busy machine does not fail it
	t0 := core.thread_cpu_now()
	for p in paths do core.reload_fs_event(p)
	took_events := core.thread_cpu_since(t0)
	t1 := core.thread_cpu_now()
	testing.expect(t, core.reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	took_flush := core.thread_cpu_since(t1)
	core.perf_expect(t, "reload_burst: 20k FSEvents paths (release builds: about half)", took_events, 20 * time.Millisecond)
	core.perf_expect(t, "reload_burst: the report", took_flush, 5 * time.Millisecond)
	log.infof("20k FSEvents paths: %v; the report: %v", took_events, took_flush)
	testing.expect_value(t, len(state.reload.changed), core.RELOAD_CHANGED_MAX)
	testing.expect_value(t, state.reload.changed_more, 20_000 - core.RELOAD_CHANGED_MAX)
	for p in state.reload.changed do testing.expectf(t, !strings.contains(p, "node_modules"), "listed: %s", p)
	testing.expect(t, state.open_sessions[0].tabs[0].reload.stale && state.open_sessions[1].tabs[0].reload.stale)
	testing.expect_value(t, state.reload.gen, u64(1))
	// only node_modules: nothing to report
	for i in 0 ..< 100 do core.reload_fs_event(fmt.tprintf("%s/extensions/pkg/node_modules/y/%d.js", ad, i))
	testing.expect(t, !core.reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
}

// pi itself writes some keys of settings.json in ordinary use (the model
// and thinking level it last used, the changelog it showed, its device
// id): a write that changes only those shows no bar; anything else does.
@(test)
reload_pi_own_settings_keys :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset("alpha")
	defer r_done()
	base := core.fs_real(fmt.tprintf("%s/pd-reload-keys-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec), context.allocator)
	ad := fmt.tprintf("%s/agent", base)
	os.make_directory_all(ad)
	os.set_env("PI_CODING_AGENT_DIR", ad)
	defer os.unset_env("PI_CODING_AGENT_DIR")
	sp := fmt.tprintf("%s/settings.json", ad)
	w :: proc(p, text: string) {_ = os.write_entire_file(p, transmute([]u8)text)}
	w(sp, `{"theme": "dark", "defaultModel": "a", "lastChangelogVersion": "1.0.0"}`)
	state.open_sessions[0].cwd = base
	core.reload_poll()
	far := time.tick_add(time.tick_now(), 2 * time.Second)
	testing.expect(t, !core.reload_flush(far))
	w(sp, `{"lastChangelogVersion": "1.4.0", "theme": "dark", "defaultProvider": "x", "defaultModel": "b", "defaultThinkingLevel": "high", "modelThinkingLevels": {"x/b": "low"}, "deviceId": "d"}`)
	core.reload_poll()
	testing.expect(t, !core.reload_flush(far), "only keys pi writes itself")
	w(sp, `{"lastChangelogVersion": "1.4.0", "theme": "light", "defaultModel": "b"}`)
	core.reload_poll()
	testing.expect(t, core.reload_flush(far), "the theme changed")
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
	os.set_env("DECKHAND_PI_PACKAGE", a)
	core.reload_tick()
	testing.expect_value(t, state.reload.pi_version, "1.0.0")
	os.set_env("DECKHAND_PI_PACKAGE", b) // pi now found elsewhere
	core.reload_pending_add("/x/settings.json", "")
	testing.expect(t, core.reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	core.reload_tick() // takes the new place, reads its version
	testing.expect(t, core.reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
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
	base := core.fs_real(fmt.tprintf("%s/pd-reload-src-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec), context.allocator)
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
	core.reload_build({proj})
	src := core.reload_sources_for_test()
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
	core.reload_fs_event(fmt.tprintf("%s/extensions/a/index.ts", kit))
	w(fmt.tprintf("%s/extensions/secret.json", ad), "{}")
	os.change_mode(fmt.tprintf("%s/extensions/secret.json", ad), os.perm_number(0o600))
	core.reload_fs_event(fmt.tprintf("%s/extensions/secret.json", ad))
	core.reload_fs_event(fmt.tprintf("%s/unrelated.txt", base))
	testing.expect(t, core.reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	testing.expect_value(t, len(state.reload.changed), 1)
	// the stat poll (built for the running tabs' folders): a context file
	// edited above the cwd reaches the tab
	state.open_sessions[0].cwd = proj
	core.reload_poll() // builds for proj; stamps as they are
	testing.expect(t, !core.reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)), "nothing changed yet")
	w(fmt.tprintf("%s/code/AGENTS.md", base), "# code, longer\n")
	core.reload_poll()
	testing.expect(t, core.reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	testing.expect(t, slice.contains(state.reload.changed[:], fmt.tprintf("%s/code/AGENTS.md", base)), "listed (with the earlier change: the tab is still stale)")
	testing.expect(t, state.open_sessions[0].tabs[0].reload.stale)
	// a new extension folder in the project: noticed, then watched
	os.make_directory_all(fmt.tprintf("%s/.pi/extensions", proj))
	core.reload_poll()
	testing.expect(t, core.reload_flush(time.tick_add(time.tick_now(), 2 * time.Second)))
	core.reload_poll()
	testing.expect(t, has(core.reload_sources_for_test(), fmt.tprintf("%s/.pi/extensions/", proj), proj))
	found := false
	for d in core.reload_watch_dirs() do if d == fmt.tprintf("%s/.pi/extensions", proj) do found = true
	testing.expect(t, found, "handed to FSEvents")
}

// ---- Claude Code (claude_reload.odin, ui_claude_reload.odin) ----

// Tests never look at the user's own Claude Code folder: a CLAUDE_CONFIG_DIR inherited from
// whatever ran the tests (a Claude Code session sets one) is dropped before any test runs; the
// tests that need one set a temp folder (with a temp HOME).
@(init, private = "file")
cr_no_user_claude :: proc "contextless" () {
	context = runtime.default_context()
	os.unset_env("CLAUDE_CONFIG_DIR")
}

@(private = "file")
CR_SCRIPT :: core.Caller{kind = .Script}
@(private = "file")
CR_CONTROL :: core.Caller{kind = .Control}

// A temp HOME with a fake Claude config folder (CLAUDE_CONFIG_DIR) and a project; never the
// user's ~/.claude. Returns the temp folder, the config folder and the project.
@(private = "file")
cr_env :: proc(tag: string) -> (base, cfg, proj: string) {
	raw := fmt.tprintf("%s/pd-creload-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), tag, time.now()._nsec)
	os.make_directory_all(raw)
	base = core.fs_real(raw, context.allocator)
	cfg = fmt.aprintf("%s/home/cfg", base)
	proj = fmt.aprintf("%s/code/proj", base)
	for d in ([]string{cfg, proj, fmt.tprintf("%s/rules", cfg), fmt.tprintf("%s/skills/s1", cfg), fmt.tprintf("%s/projects/-p", cfg), fmt.tprintf("%s/.claude/commands", proj)}) do os.make_directory_all(d)
	os.set_env("HOME", fmt.tprintf("%s/home", base))
	os.set_env("CLAUDE_CONFIG_DIR", cfg)
	wd, _ := os.get_working_directory(context.temp_allocator)
	os.set_env("DECKHAND_CLAUDE_PLUGIN", fmt.tprintf("%s/integrations/claude-code", wd))
	os.unset_env("DECKHAND_CLAUDE_BIN")
	core.claude_reload_watch_reset()
	core.dead_tab_reset()
	core.claude_installed_probe = stand_in_installed // the stand-in claude counts as installed
	return
}

@(private = "file")
cr_done :: proc() {
	r_done()
	core.claude_reload_watch_reset()
	core.dead_tab_reset()
	core.claude_installed_probe = nil
	os.unset_env("CLAUDE_CONFIG_DIR")
	os.unset_env("DECKHAND_CLAUDE_BIN")
	os.set_env("DECKHAND_CLAUDE_CMD", "sleep 30")
}

@(private = "file")
cr_w :: proc(p, text: string) {_ = os.write_entire_file(p, transmute([]u8)text)}

// An open session at cwd (its pi tab "running", no process) for Claude tabs.
@(private = "file")
cr_session :: proc(cwd: string) -> u64 {
	s := core.Open_Session{id = core.new_id(), pi_session_id = strings.clone("pi-cr"), cwd = strings.clone(cwd)}
	append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	state.current_session = s.id
	return s.id
}

// A fake claude that writes its arguments (one per line) to args, then sleeps.
@(private = "file")
cr_args_cmd :: proc(args: string) -> string {
	return fmt.tprintf(`printf '%%s\n' "$@" > '%s.tmp'; mv '%s.tmp' '%s'; exec sleep 30`, args, args, args)
}

@(private = "file")
// Up to 20 s (a fake claude's start under load: 3 s was once too short), no slower when it passes.
cr_has :: proc(path, want: string) -> bool {
	deadline := time.tick_add(time.tick_now(), 20 * time.Second)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		data, _ := os.read_entire_file(path, context.temp_allocator)
		if strings.contains(string(data), want) do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// Waits until a restarted tab runs again (the old process gone: dead_tab_tick starts it).
@(private = "file")
cr_running_again :: proc(id: u64) -> bool {
	// up to 20 s (500 rounds of 10 ms, ~5 s, timed out on CI under load), no slower when it passes
	deadline := time.tick_add(time.tick_now(), 20 * time.Second)
	for time.tick_diff(time.tick_now(), deadline) > 0 {
		core.pump_all()
		core.pty_reap()
		core.dead_tab_tick()
		if _, tab, _ := core.find_tab(id); tab != nil && tab.status == .Running && !core.restart_waiting(id) do return true
		time.sleep(10 * time.Millisecond)
	}
	return false
}

// Which Claude files a running session reads anew only when it starts (a restart, --resume)
// and which Claude Code applies live (no bar): Claude Code's docs, "When edits take effect".
@(test)
claude_reload_classify :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset()
	defer cr_done()
	base, cfg, proj := cr_env("class")
	home := fmt.tprintf("%s/home", base)
	plugin := os.get_env("DECKHAND_CLAUDE_PLUGIN", context.temp_allocator)
	C :: core.Claude_File_Class
	Case :: struct {
		p:    string,
		want: C,
	}
	cases := []Case {
		// live: settings files (watched by Claude Code), keybindings, skills, subagents
		{fmt.tprintf("%s/settings.json", cfg), .Live},
		{fmt.tprintf("%s/keybindings.json", cfg), .Live},
		{fmt.tprintf("%s/skills/s1/SKILL.md", cfg), .Live},
		{fmt.tprintf("%s/agents/a.md", cfg), .Live},
		{fmt.tprintf("%s/.claude/settings.json", proj), .Live},
		{fmt.tprintf("%s/.claude/settings.local.json", proj), .Live},
		{fmt.tprintf("%s/.claude/skills/x/SKILL.md", proj), .Live},
		{fmt.tprintf("%s/.claude/agents/x.md", proj), .Live},
		// read at start: instructions, rules, output styles, commands, MCP servers, the plugin
		{fmt.tprintf("%s/CLAUDE.md", cfg), .Restart},
		{fmt.tprintf("%s/rules/r.md", cfg), .Restart},
		{fmt.tprintf("%s/output-styles/s.md", cfg), .Restart},
		{fmt.tprintf("%s/commands/c.md", cfg), .Restart},
		{fmt.tprintf("%s/CLAUDE.md", proj), .Restart},
		{fmt.tprintf("%s/CLAUDE.local.md", proj), .Restart},
		{fmt.tprintf("%s/.claude/CLAUDE.md", proj), .Restart},
		{fmt.tprintf("%s/.claude/rules/r.md", proj), .Restart},
		{fmt.tprintf("%s/.claude/commands/c.md", proj), .Restart},
		{fmt.tprintf("%s/.mcp.json", proj), .Restart},
		{fmt.tprintf("%s/code/CLAUDE.md", base), .Restart},
		{fmt.tprintf("%s/hooks/hooks.json", plugin), .Restart},
		// never: credentials, account state, transcripts, anything else
		{fmt.tprintf("%s/.credentials.json", cfg), .Ignored},
		{fmt.tprintf("%s/.claude.json", cfg), .Ignored},
		{fmt.tprintf("%s/.claude.json", home), .Ignored},
		{fmt.tprintf("%s/projects/-p/s.jsonl", cfg), .Ignored},
		{fmt.tprintf("%s/history.jsonl", cfg), .Ignored},
		{fmt.tprintf("%s/sessions/1.json", cfg), .Ignored},
		{fmt.tprintf("%s/plugins/installed_plugins.json", cfg), .Ignored},
		{fmt.tprintf("%s/src/main.go", proj), .Ignored},
		{fmt.tprintf("%s/.env", proj), .Ignored},
	}
	for c in cases do testing.expectf(t, core.claude_file_class(c.p) == c.want, "%s: %v, want %v", c.p, core.claude_file_class(c.p), c.want)
}

// What is watched for a running Claude tab: only what needs a restart, and never a credential,
// account or transcript file (nothing in the config folder but its config).
@(test)
claude_reload_sources :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset()
	defer cr_done()
	base, cfg, proj := cr_env("src")
	home := fmt.tprintf("%s/home", base)
	for f in ([]string{"CLAUDE.md", "settings.json", "keybindings.json", ".credentials.json", "history.jsonl", "projects/-p/s.jsonl"}) do cr_w(fmt.tprintf("%s/%s", cfg, f), "{}")
	cr_w(fmt.tprintf("%s/.claude.json", home), "{}")
	cr_w(fmt.tprintf("%s/code/CLAUDE.md", base), "# code\n")
	cr_w(fmt.tprintf("%s/.mcp.json", proj), "{}")
	core.claude_reload_build({proj})
	src := core.claude_reload_sources_for_test()
	has :: proc(m: map[string]string, k, scope: string) -> bool {v, ok := m[k]; return ok && v == scope}
	plugin := os.get_env("DECKHAND_CLAUDE_PLUGIN", context.temp_allocator)
	testing.expect(t, has(src, fmt.tprintf("%s/CLAUDE.md", cfg), ""), "the global CLAUDE.md")
	testing.expect(t, has(src, fmt.tprintf("%s/rules/", cfg), ""), "the global rules")
	testing.expect(t, has(src, fmt.tprintf("%s/output-styles/", cfg), ""), "output styles (missing: watched for being made)")
	testing.expect(t, has(src, fmt.tprintf("%s/commands/", cfg), ""), "commands")
	testing.expect(t, has(src, fmt.tprintf("%s/agents/", cfg), ""), "a missing agents folder (Claude Code only watches folders there at start)")
	testing.expect(t, has(src, fmt.tprintf("%s/hooks/hooks.json", plugin), ""), "Deckhand's plugin")
	testing.expect(t, has(src, fmt.tprintf("%s/code/CLAUDE.md", base), fmt.tprintf("%s/code", base)), "CLAUDE.md above the cwd")
	testing.expect(t, has(src, fmt.tprintf("%s/CLAUDE.md", proj), proj), "the cwd's (missing) CLAUDE.md")
	testing.expect(t, has(src, fmt.tprintf("%s/CLAUDE.local.md", proj), proj), "CLAUDE.local.md")
	testing.expect(t, has(src, fmt.tprintf("%s/.mcp.json", proj), proj), "the project's MCP servers")
	testing.expect(t, has(src, fmt.tprintf("%s/.claude/commands/", proj), proj), "the project's commands")
	for k, _ in src {
		for never in ([]string{"settings.json", "keybindings.json", ".credentials", ".claude.json", "/projects/-p", "history.jsonl", "/skills/s1"}) {
			testing.expectf(t, !strings.contains(k, never), "never watched: %s", k)
		}
	}
	// the poll notices a change in a watched folder's files (an edited command), not in live ones
	core.claude_reload_build({})
	sess := cr_session(proj)
	os.set_env("DECKHAND_CLAUDE_CMD", "exec sleep 30")
	id := core.run_command(core.New_Claude_Tab{session = sess}, R_UI).created_id
	testing.expect(t, id != 0)
	core.claude_reload_tick()
	core.claude_reload_poll_now()
	testing.expect_value(t, len(state.reload.claude.changed), 0)
	cr_w(fmt.tprintf("%s/settings.json", cfg), `{"model":"x"}`) // live: no bar
	cr_w(fmt.tprintf("%s/.claude/commands/c.md", proj), "do it\n")
	core.claude_reload_poll_now()
	testing.expect_value(t, len(state.reload.claude.changed), 1)
	testing.expect(t, slice.contains(state.reload.claude.changed[:], fmt.tprintf("%s/.claude/commands", proj)), "the commands folder")
	_, tab, _ := core.find_tab(id)
	testing.expect(t, tab.reload.stale, "the tab is stale")
	// the bar's text, and no pi bar for it
	testing.expect(t, claude_bar_shows(false))
	testing.expect(t, !reload_bar_shows(), "pi's bar is pi's")
}

// The bar's Restart: idle Claude tabs start again now with --resume (the user's flags only for
// the user), busy ones once idle; one that never reported its conversation is left alone.
// Restarting stops Claude's background work, so the user confirms.
@(test)
claude_reload_restart_flow :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset()
	defer cr_done()
	base, cfg, proj := cr_env("flow")
	args := fmt.tprintf("%s/args", base)
	os.set_env("DECKHAND_CLAUDE_CMD", cr_args_cmd(args))
	sess := cr_session(proj)
	idle := core.run_command(core.New_Claude_Tab{session = sess, args = {"--model", "opus"}}, R_UI).created_id
	busy := core.run_command(core.New_Claude_Tab{session = sess}, R_UI).created_id
	none := core.run_command(core.New_Claude_Tab{session = sess}, R_UI).created_id
	core.run_command(core.Claude_Session_Report{tab_id = idle, session_id = "0c1a0de0-aaaa-4222-8333-444455556661", source = "startup"}, CR_SCRIPT)
	core.run_command(core.Claude_Session_Report{tab_id = busy, session_id = "0c1a0de0-aaaa-4222-8333-444455556662", source = "startup"}, CR_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = idle, state = "idle"}, CR_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = busy, state = "submitted"}, CR_SCRIPT)
	core.claude_reload_tick()
	testing.expect(t, !claude_bar_shows(false), "nothing changed")
	testing.expect(t, core.run_command(core.Claude_Reload_Watch{paths = {fmt.tprintf("%s/CLAUDE.md", cfg)}, scopes = {""}}).ok)
	_, it, _ := core.find_tab(idle)
	testing.expect(t, it.reload.stale)
	msg, can := claude_reload_message(false)
	testing.expect_value(t, msg, "Claude Code settings changed — Restart 1 idle Claude tab · 1 busy when idle")
	testing.expect(t, can)
	// a scoped change reaches only the tabs at or below it
	core.run_command(core.Claude_Reload_Later{})
	testing.expect(t, !claude_bar_shows(false), "Later hides it")
	for &x in core.find_session(sess).tabs do x.reload.stale = false
	core.run_command(core.Claude_Reload_Watch{paths = {"/elsewhere/CLAUDE.md"}, scopes = {"/elsewhere"}})
	testing.expect(t, !it.reload.stale, "another folder's file")
	testing.expect(t, !claude_bar_shows(false))
	core.run_command(core.Claude_Reload_Watch{paths = {fmt.tprintf("%s/CLAUDE.md", proj)}, scopes = {proj}})
	testing.expect(t, it.reload.stale)
	testing.expect(t, claude_bar_shows(false), "a new change shows it again")
	// the user's Restart: confirmed first (background work stops)
	r := core.run_command(core.Claude_Restart_Changed{}, R_UI)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expectf(t, strings.contains(r.confirm_summary, "background"), "says what stops: %s", r.confirm_summary)
	os.remove(args)
	r = core.run_command(core.Claude_Restart_Changed{confirm = r.confirm_token}, R_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, core.json_path(r.data, "restarting.#"), "1")
	testing.expect_value(t, core.json_path(r.data, "restarting.0"), fmt.tprint(idle))
	testing.expect_value(t, core.json_path(r.data, "queued.#"), "1")
	testing.expect_value(t, core.json_path(r.data, "queued.0"), fmt.tprint(busy))
	testing.expect_value(t, core.json_path(r.data, "no_session.#"), "1")
	testing.expect_value(t, core.json_path(r.data, "no_session.0"), fmt.tprint(none))
	testing.expect(t, cr_running_again(idle), "the idle tab runs again")
	testing.expect(t, cr_has(args, "--resume\n0c1a0de0-aaaa-4222-8333-444455556661\n--model\nopus"), "resumed with the user's flags")
	_, it, _ = core.find_tab(idle)
	testing.expect(t, !it.reload.stale, "fresh")
	// the busy one waits; typing holds it too; it goes once idle and untouched
	_, bt, _ := core.find_tab(busy)
	testing.expect_value(t, bt.reload.queued, core.Reload_Op.Restart)
	core.run_command(core.Claude_Turn_Report{tab_id = busy, state = "idle"}, CR_SCRIPT)
	core.claude_note_typed(bt)
	core.claude_reload_tick()
	testing.expect_value(t, bt.status, core.Tab_Status.Running) // not while the user types
	core.run_command(core.Claude_Turn_Report{tab_id = busy, state = "submitted"}, CR_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = busy, state = "idle"}, CR_SCRIPT)
	os.remove(args)
	core.claude_reload_tick()
	testing.expect(t, cr_running_again(busy))
	testing.expect(t, cr_has(args, "--resume\n0c1a0de0-aaaa-4222-8333-444455556662"))
	_, bt, _ = core.find_tab(busy)
	testing.expect_value(t, bt.reload.queued, core.Reload_Op.None)
	// the one without a conversation id runs on, untouched
	_, nt, _ := core.find_tab(none)
	testing.expect_value(t, nt.status, core.Tab_Status.Running)
	// Atlas (control) may ask; the user confirms; the snapshot shows the bar's model
	core.run_command(core.Claude_Reload_Watch{paths = {fmt.tprintf("%s/CLAUDE.md", cfg)}, scopes = {""}})
	rc := core.run_command(core.Claude_Restart_Changed{}, CR_CONTROL)
	testing.expect_value(t, rc.error, "needs_confirmation")
	testing.expect(t, rc.confirm_by_user)
	testing.expect(t, core.command_spec("claude_restart_changed") != nil)
	testing.expect(t, core.command_spec("claude_reload_later") != nil)
	testing.expect(t, !core.caller_may(core.Caller{kind = .Panel, tab_id = idle, claude = true}, core.Claude_Restart_Changed{}), "a Claude tab never restarts tabs")
	c, err := core.parse_command(`{"type":"claude_restart_changed","update":true}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.(core.Claude_Restart_Changed).update, true)
	snap := core.json_path(core.run_command(core.Get_State{}, R_UI).data, "reload.claude.changed.0")
	testing.expect(t, strings.contains(snap, "CLAUDE.md"), snap)
}

// Claude Code updated under running tabs: found by where `claude` links to (stat only: never run),
// each tab keeps the version it started with, the bar offers Restart.
@(test)
claude_version_drift :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset()
	defer cr_done()
	base, _, proj := cr_env("ver")
	ran := fmt.tprintf("%s/ran", base)
	fake := fmt.tprintf("#!/bin/sh\ntouch '%s'\n", ran) // proves it is never run
	vers := fmt.tprintf("%s/home/.local/share/claude/versions", base)
	os.make_directory_all(vers)
	for v in ([]string{"2.1.300", "2.1.301"}) {
		cr_w(fmt.tprintf("%s/%s", vers, v), fake)
		os.change_mode(fmt.tprintf("%s/%s", vers, v), os.perm_number(0o755))
	}
	bin := fmt.tprintf("%s/home/.local/bin", base)
	os.make_directory_all(bin)
	link := fmt.tprintf("%s/claude", bin)
	os.symlink(fmt.tprintf("%s/2.1.300", vers), link)
	// how a version is read from an install's layout
	label, ident := core.claude_version_of(link)
	testing.expect_value(t, label, "2.1.300")
	testing.expect_value(t, ident, "2.1.300")
	cask := fmt.tprintf("%s/Caskroom/claude-code/2.1.299", base)
	os.make_directory_all(cask)
	cr_w(fmt.tprintf("%s/claude", cask), fake)
	label, _ = core.claude_version_of(fmt.tprintf("%s/claude", cask))
	testing.expect_value(t, label, "2.1.299")
	latest := fmt.tprintf("%s/Caskroom/claude-code@latest/2.1.301", base) // the latest channel's cask
	os.make_directory_all(latest)
	cr_w(fmt.tprintf("%s/claude", latest), fake)
	label, _ = core.claude_version_of(fmt.tprintf("%s/claude", latest))
	testing.expect_value(t, label, "2.1.301")
	npm := fmt.tprintf("%s/lib/node_modules/@anthropic-ai/claude-code", base)
	os.make_directory_all(npm)
	cr_w(fmt.tprintf("%s/cli.js", npm), fake)
	cr_w(fmt.tprintf("%s/package.json", npm), `{"name":"@anthropic-ai/claude-code","version":"2.1.250"}`)
	os.symlink(fmt.tprintf("%s/cli.js", npm), fmt.tprintf("%s/npm-claude", base))
	label, _ = core.claude_version_of(fmt.tprintf("%s/npm-claude", base))
	testing.expect_value(t, label, "2.1.250")
	other := fmt.tprintf("%s/other-claude", base)
	cr_w(other, fake)
	label, ident = core.claude_version_of(other)
	testing.expect_value(t, label, "")
	testing.expect(t, strings.has_prefix(ident, "build:"), ident) // unknown layout: its file's identity
	label, _ = core.claude_version_of(fmt.tprintf("%s/missing", base))
	testing.expect_value(t, label, "")
	// tests replace claude (DECKHAND_CLAUDE_CMD): no version unless DECKHAND_CLAUDE_BIN names one
	os.set_env("DECKHAND_CLAUDE_CMD", "exec sleep 30")
	testing.expect_value(t, core.claude_binary_path(), "")
	os.set_env("DECKHAND_CLAUDE_BIN", link)
	testing.expect_value(t, core.claude_binary_path(), link)
	// a running tab records the version on disk
	sess := cr_session(proj)
	id := core.run_command(core.New_Claude_Tab{session = sess}, R_UI).created_id
	core.run_command(core.Claude_Session_Report{tab_id = id, session_id = "0c1a0de0-aaaa-4222-8333-444455556663", source = "startup"}, CR_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = id, state = "idle"}, CR_SCRIPT)
	core.claude_reload_tick()
	core.claude_reload_poll_now()
	core.claude_reload_tick()
	testing.expect_value(t, state.reload.claude.version, "2.1.300")
	_, tab, _ := core.find_tab(id)
	testing.expect_value(t, tab.reload.version, "2.1.300")
	testing.expect(t, !core.claude_reload_outdated(tab))
	testing.expect(t, !claude_bar_shows(true))
	// an update relinks claude
	os.remove(link)
	os.symlink(fmt.tprintf("%s/2.1.301", vers), link)
	core.claude_reload_poll_now()
	testing.expect_value(t, state.reload.claude.version, "2.1.301")
	testing.expect(t, core.claude_reload_outdated(tab))
	msg, can := claude_reload_message(true)
	testing.expect_value(t, msg, "Claude Code updated to 2.1.301 — Restart 1 idle Claude tab")
	testing.expect(t, can)
	// Later: hidden until the next version
	core.run_command(core.Claude_Reload_Later{update = true})
	testing.expect(t, !claude_bar_shows(true))
	state.reload.claude.update_dismissed = false
	r := core.run_command(core.Claude_Restart_Changed{update = true}, R_UI)
	r = core.run_command(core.Claude_Restart_Changed{update = true, confirm = r.confirm_token}, R_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect(t, cr_running_again(id))
	core.claude_reload_tick()
	_, tab, _ = core.find_tab(id)
	testing.expect_value(t, tab.reload.version, "2.1.301")
	testing.expect(t, !claude_bar_shows(true))
	testing.expect(t, !os.exists(ran), "claude itself never ran")
}

// Saving a Claude file in Deckhand's editor shows the bar at once when Claude needs a restart for
// it; a file it applies live (settings.json) shows nothing.
@(test)
claude_reload_after_save :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset()
	defer cr_done()
	_, cfg, _ := cr_env("save")
	core.settings_after_save(0, fmt.tprintf("%s/settings.json", cfg))
	core.claude_reload_flush(time.tick_add(time.tick_now(), 2 * time.Second))
	testing.expect_value(t, len(state.reload.claude.changed), 0)
	testing.expect(t, !claude_bar_shows(false))
	core.settings_after_save(0, fmt.tprintf("%s/CLAUDE.md", cfg))
	core.claude_reload_flush(time.tick_add(time.tick_now(), 2 * time.Second))
	testing.expect(t, state.reload.claude.from_save)
	testing.expect(t, claude_bar_shows(false))
	msg, can := claude_reload_message(false)
	testing.expect_value(t, msg, "Claude Code settings changed — new Claude tabs use it")
	testing.expect(t, !can)
}

// An agent's Restart, confirmed by the user in Deckhand: still the agent's restart (never its own
// session's Claude tabs, never the user's saved flags); every caller but Deckhand's own is asked,
// whatever its confirm policy; only the user hides the bar.
@(test)
claude_reload_agent_confirm :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset()
	defer cr_done()
	base, cfg, proj := cr_env("agent")
	args := fmt.tprintf("%s/args", base)
	os.set_env("DECKHAND_CLAUDE_CMD", cr_args_cmd(args))
	mine_s := cr_session(proj)
	agent := core.Caller{kind = .Control, tab_id = core.find_session(mine_s).tabs[0].id}
	mine := core.run_command(core.New_Claude_Tab{session = mine_s}, R_UI).created_id
	other_s := cr_session(proj)
	other := core.run_command(core.New_Claude_Tab{session = other_s, args = {"--model", "opus"}}, R_UI).created_id
	for x in ([][2]u64{{mine, 1}, {other, 2}}) {
		core.run_command(core.Claude_Session_Report{tab_id = x[0], session_id = fmt.tprintf("0c1a0de0-aaaa-4222-8333-44445555668%d", x[1]), source = "startup"}, CR_SCRIPT)
		core.run_command(core.Claude_Turn_Report{tab_id = x[0], state = "idle"}, CR_SCRIPT)
	}
	core.claude_reload_tick()
	core.run_command(core.Claude_Reload_Watch{paths = {fmt.tprintf("%s/CLAUDE.md", cfg)}, scopes = {""}})
	r := core.run_command(core.Claude_Restart_Changed{}, agent)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expect(t, r.confirm_by_user)
	testing.expect_value(t, len(state.pending_confirmations), 1)
	os.remove(args)
	if len(state.pending_confirmations) == 1 {
		confirm_pending(state.pending_confirmations[0].token)
		core.inbox_drain()
	}
	testing.expect(t, cr_running_again(other), "the other session's tab restarted")
	testing.expect(t, cr_has(args, "--resume\n0c1a0de0-aaaa-4222-8333-444455556682"))
	data, _ := os.read_entire_file(args, context.temp_allocator)
	testing.expectf(t, !strings.contains(string(data), "--model"), "an agent's restart replays no saved flags: %q", string(data))
	_, mt, _ := core.find_tab(mine)
	testing.expect(t, !core.restart_waiting(mine) && mt.status == .Running && mt.reload.stale, "the agent's own session is left alone")
	// a script trusted (or auto) for session restarts: the user still confirms (pi panels may not ask)
	for kind in ([]core.Caller_Kind{.Script}) {
		for mode in ([]core.Confirm_Mode{.Trusted, .Auto}) {
			state.settings.confirm[kind][.Session_Restart] = mode
			core.run_command(core.Claude_Reload_Watch{paths = {fmt.tprintf("%s/CLAUDE.md", cfg)}, scopes = {""}})
			c := core.Caller{kind = kind}
			rr := core.run_command(core.Claude_Restart_Changed{}, c)
			testing.expectf(t, rr.error == "needs_confirmation" && rr.confirm_by_user && rr.confirm_token == "", "%v %v: %v", kind, mode, rr)
			clear(&state.pending_confirmations)
		}
	}
	// Later is the user's (as pi's)
	testing.expect_value(t, core.command_spec("claude_reload_later").who, core.Command_Who.User)
	testing.expect(t, !core.caller_may(CR_CONTROL, core.Claude_Reload_Later{}), "an agent never hides the bar")
}

// A file saved deep in a project's .claude (rules/sub/x.md) reaches that project's tabs.
@(test)
claude_reload_scope_nested :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset()
	defer cr_done()
	_, _, proj := cr_env("nested")
	os.set_env("DECKHAND_CLAUDE_CMD", "exec sleep 30")
	sess := cr_session(proj)
	id := core.run_command(core.New_Claude_Tab{session = sess}, R_UI).created_id
	core.claude_reload_tick()
	os.make_directory_all(fmt.tprintf("%s/.claude/rules/sub", proj))
	p := fmt.tprintf("%s/.claude/rules/sub/x.md", proj)
	cr_w(p, "# rule\n")
	core.settings_after_save(0, p)
	core.claude_reload_flush(time.tick_add(time.tick_now(), 2 * time.Second))
	_, tab, _ := core.find_tab(id)
	testing.expect(t, tab.reload.stale, "the project's tab needs a restart")
}

// Restart all Claude tabs (the palette and the gear's popover): every running Claude tab, changed
// or not, idle ones now and busy ones once idle, each with --resume; always confirmed; the
// user's saved flags only on the user's restart (as claude_restart_changed).
@(test)
claude_restart_all :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r_reset()
	defer cr_done()
	base, _, proj := cr_env("all")
	args := fmt.tprintf("%s/args", base)
	os.set_env("DECKHAND_CLAUDE_CMD", cr_args_cmd(args))
	sess := cr_session(proj)
	idle := core.run_command(core.New_Claude_Tab{session = sess, args = {"--model", "opus"}}, R_UI).created_id
	busy := core.run_command(core.New_Claude_Tab{session = sess}, R_UI).created_id
	none := core.run_command(core.New_Claude_Tab{session = sess}, R_UI).created_id
	core.run_command(core.Claude_Session_Report{tab_id = idle, session_id = "0c1a0de0-aaaa-4222-8333-444455556691", source = "startup"}, CR_SCRIPT)
	core.run_command(core.Claude_Session_Report{tab_id = busy, session_id = "0c1a0de0-aaaa-4222-8333-444455556692", source = "startup"}, CR_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = idle, state = "idle"}, CR_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = busy, state = "submitted"}, CR_SCRIPT)
	core.claude_reload_tick()
	// nothing changed: the bar's Restart has nothing to do, restart-all still does
	testing.expect(t, !core.run_command(core.Claude_Restart_Changed{}, R_UI).ok, "nothing changed")
	testing.expect(t, action_ok("restart_all_claude"), "the palette offers it while a Claude tab runs")
	testing.expect_value(t, POP_ACTIONS[.Restart_Claude], "restart_all_claude") // its button: the gear's popover
	testing.expect(t, !action_ok("restart_changed_claude"), "nothing changed: not offered")
	r := core.run_command(core.Claude_Restart_Changed{all = true}, R_UI)
	testing.expect_value(t, r.error, "needs_confirmation")
	testing.expectf(t, strings.contains(r.confirm_summary, "Restart 2 Claude tabs?"), "%s", r.confirm_summary)
	os.remove(args)
	r = core.run_command(core.Claude_Restart_Changed{all = true, confirm = r.confirm_token}, R_UI)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, core.json_path(r.data, "restarting.0"), fmt.tprint(idle))
	testing.expect_value(t, core.json_path(r.data, "queued.0"), fmt.tprint(busy))
	testing.expect_value(t, core.json_path(r.data, "no_session.0"), fmt.tprint(none))
	testing.expect(t, cr_running_again(idle), "the idle tab runs again")
	testing.expect(t, cr_has(args, "--resume\n0c1a0de0-aaaa-4222-8333-444455556691\n--model\nopus"), "the user's restart replays the saved flags")
	// the busy one goes once idle, though nothing changed
	_, bt, _ := core.find_tab(busy)
	testing.expect_value(t, bt.reload.queued, core.Reload_Op.Restart)
	core.run_command(core.Claude_Turn_Report{tab_id = busy, state = "idle"}, CR_SCRIPT)
	os.remove(args)
	core.claude_reload_tick()
	testing.expect(t, cr_running_again(busy), "the queued tab restarted once idle")
	testing.expect(t, cr_has(args, "--resume\n0c1a0de0-aaaa-4222-8333-444455556692"))
	// an agent may ask; the user confirms; no saved flags then
	core.run_command(core.Claude_Session_Report{tab_id = idle, session_id = "0c1a0de0-aaaa-4222-8333-444455556691", source = "resume"}, CR_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = idle, state = "idle"}, CR_SCRIPT)
	core.run_command(core.Claude_Session_Report{tab_id = busy, session_id = "0c1a0de0-aaaa-4222-8333-444455556692", source = "resume"}, CR_SCRIPT)
	core.run_command(core.Claude_Turn_Report{tab_id = busy, state = "idle"}, CR_SCRIPT)
	rc := core.run_command(core.Claude_Restart_Changed{all = true}, CR_CONTROL)
	testing.expect_value(t, rc.error, "needs_confirmation")
	testing.expect(t, rc.confirm_by_user)
	os.remove(args)
	if len(state.pending_confirmations) == 1 {
		confirm_pending(state.pending_confirmations[0].token)
		core.inbox_drain()
	}
	testing.expect(t, cr_running_again(idle))
	data, _ := os.read_entire_file(args, context.temp_allocator)
	testing.expectf(t, !strings.contains(string(data), "--model"), "an agent's restart replays no saved flags: %q", string(data))
	c, err := core.parse_command(`{"type":"claude_restart_changed","all":true}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect_value(t, c.(core.Claude_Restart_Changed).all, true)
	testing.expect(t, strings.contains(core.command_spec("claude_restart_changed").args, "all?"))
}
