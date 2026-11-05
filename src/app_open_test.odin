package main

// A session's own agents (a pi tab's bridge, a Claude tab's CLI: caller panel) open, restart and
// close app tabs in their own session only, by the name the project declares in
// .pi-desk/apps.json; never another session's, never an argv of their own, never in front of the
// user. Home (control) keeps what it had: argv, any session it names, the tab in front.
// The apps here never start (a program that is not there): what is checked is who may open what
// and where; the live side is tests/scripts/app-open.sh and the claude scene.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
AO_MISSING :: "/nonexistent/pi-desk-test-app" // posix_spawnp fails: no process, no GPU

// Two sessions in real folders (a declares "fake" and "other", b declares "fake") and Home.
@(private = "file")
ao_reset :: proc(t: ^testing.T) -> (a, b, home: u64, dir: string) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	platform = {}
	frames_ok = -1 // no frame server in unit tests
	dir = fmt.aprintf("build/test-data/app-open-%d", os.get_pid())
	for name in ([]string{"alpha", "beta"}) {
		cwd, _ := filepath.join({dir, name}, context.allocator)
		os.make_directory_all(strings.concatenate({cwd, "/.pi-desk"}, context.temp_allocator))
		apps := name == "alpha" ? fmt.tprintf(`{{"apps":[{{"name":"fake","argv":[%q,"--x"]}},{{"name":"other","argv":[%q]}}]}}`, AO_MISSING, AO_MISSING) : fmt.tprintf(`{{"apps":[{{"name":"fake","argv":[%q]}}]}}`, AO_MISSING)
		_ = os.write_entire_file(strings.concatenate({cwd, "/.pi-desk/apps.json"}, context.temp_allocator), transmute([]u8)apps)
		s := Open_Session{id = new_id(), pi_session_id = fmt.aprintf("pi-%s", name), cwd = fs_real(cwd)}
		append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
	}
	h := Open_Session{id = new_id(), home = true}
	append(&h.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "Home", status = .Running})
	h.active_tab = h.tabs[0].id
	append(&state.open_sessions, h)
	state.home = h.id
	state.current_session = state.open_sessions[1].id // the user looks at b
	return state.open_sessions[0].id, state.open_sessions[1].id, h.id, dir
}

@(private = "file")
ao_done :: proc(dir: string) {
	for s in state.open_sessions do for tab in s.tabs do if _, is := tab.kind.(App_Tab); is do run_command(Close_Tab{tab_id = tab.id}, {kind = .Internal})
	os.remove_all(dir)
}

@(private = "file")
ao_first :: proc(session: u64) -> u64 {return find_session(session).tabs[0].id}

@(private = "file")
ao_count :: proc(session: u64) -> int {return len(find_session(session).tabs)}

// A pi tab and a Claude tab open their project's declared apps in their own session, behind the
// user's view; another session, an argv, an unknown name are refused.
@(test)
app_open_own_session_by_name :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, _, dir := ao_reset(t)
	defer ao_done(dir)
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	// a Claude tab in a (its CLI's token: panel + claude)
	sa := find_session(a)
	cl_id := new_id()
	append(&sa.tabs, Tab{id = cl_id, kind = Claude_Tab{}, title = "claude", status = .Running})
	claude := Caller{kind = .Panel, tab_id = cl_id, claude = true}
	for caller in ([]Caller{pi, claude}) {
		testing.expectf(t, caller_may(caller, New_App_Tab{}), "%v may send new_app_tab", caller)
		before := ao_count(a)
		r := run_command(New_App_Tab{name = "fake"}, caller)
		testing.expectf(t, r.ok && r.created_id != 0, "opens its declared app: %s", r.error)
		s, tab, _ := find_tab(r.created_id)
		testing.expect(t, s != nil && s.id == a, "in its own session")
		testing.expect_value(t, ao_count(a), before + 1)
		if tab != nil {
			testing.expect_value(t, tab.title, "fake")
			at, is := tab.kind.(App_Tab)
			testing.expect(t, is && len(at.argv) == 2 && at.argv[0] == AO_MISSING && at.argv[1] == "--x", "the declared argv")
		}
		// behind the user's view: neither the session on screen nor a's active tab changes
		testing.expect_value(t, state.current_session, b)
		testing.expect_value(t, find_session(a).active_tab, ao_first(a))
		// naming its own session is fine
		r = run_command(New_App_Tab{session = a, name = "other"}, caller)
		testing.expectf(t, r.ok, "its own session by id: %s", r.error)
		// another session: refused, nothing opened there
		nb := ao_count(b)
		r = run_command(New_App_Tab{session = b, name = "fake"}, caller)
		testing.expectf(t, !r.ok && strings.contains(r.error, "own session"), "another session refused: %s", r.error)
		testing.expect_value(t, ao_count(b), nb)
		// a program of its own: refused (only what the project declares)
		n := ao_count(a)
		r = run_command(New_App_Tab{argv = {"/bin/sh"}}, caller)
		testing.expectf(t, !r.ok && strings.contains(r.error, "apps.json"), "argv refused: %s", r.error)
		r = run_command(New_App_Tab{command = "echo hi"}, caller)
		testing.expectf(t, !r.ok && strings.contains(r.error, "apps.json"), "command refused: %s", r.error)
		r = run_command(New_App_Tab{name = "fake", argv = {"/bin/sh"}}, caller)
		testing.expect(t, !r.ok, "name and argv together refused")
		// not declared: refused, with the declared names
		r = run_command(New_App_Tab{name = "nope"}, caller)
		testing.expectf(t, !r.ok && strings.contains(r.error, "fake") && strings.contains(r.error, "other"), "unknown name lists the declared: %s", r.error)
		testing.expect_value(t, ao_count(a), n)
	}
}

// What a session declares: its own for a pi tab; another session's refused.
@(test)
app_declared_own_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, _, dir := ao_reset(t)
	defer ao_done(dir)
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	r := run_command(App_Declared{}, pi)
	testing.expectf(t, r.ok && strings.contains(r.data, `"name":"fake"`) && strings.contains(r.data, `"name":"other"`), "its own: %s %s", r.error, r.data)
	r = run_command(App_Declared{session = b}, pi)
	testing.expectf(t, !r.ok && strings.contains(r.error, "own session"), "another session's: %s", r.error)
	r = run_command(App_Declared{session = b}, {kind = .Control})
	testing.expectf(t, r.ok && strings.contains(r.data, `"name":"fake"`) && !strings.contains(r.data, "other"), "control names a session: %s %s", r.error, r.data)
}

// Restart and close: a session's agents on their own session's app tabs only.
@(test)
app_restart_close_own_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, _, dir := ao_reset(t)
	defer ao_done(dir)
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	mine := run_command(New_App_Tab{name = "fake"}, pi).created_id
	theirs := run_command(New_App_Tab{session = b, name = "fake"}, {kind = .UI}).created_id
	testing.expect(t, mine != 0 && theirs != 0, "both opened")
	testing.expect(t, caller_may(pi, App_Restart{}) && caller_may(pi, App_Close{}), "a pi tab may send them")
	// another session's: refused, still there
	r := run_command(App_Restart{tab_id = theirs}, pi)
	testing.expectf(t, !r.ok && strings.contains(r.error, "own session"), "restart of another session's: %s", r.error)
	r = run_command(App_Close{tab_id = theirs}, pi)
	testing.expectf(t, !r.ok && strings.contains(r.error, "own session"), "close of another session's: %s", r.error)
	_, tab, _ := find_tab(theirs)
	testing.expect(t, tab != nil, "another session's app tab stays")
	// not an app tab (its own pi tab, a shell): refused
	r = run_command(App_Close{tab_id = ao_first(a)}, pi)
	testing.expectf(t, !r.ok && strings.contains(r.error, "app tab"), "a pi tab is not an app tab: %s", r.error)
	// its own: restart goes through (the program is not there: it could not start), close closes
	r = run_command(App_Restart{tab_id = mine}, pi)
	testing.expectf(t, r.error == "could not start the app", "restart reached the app: %s", r.error)
	r = run_command(App_Close{tab_id = mine}, pi)
	testing.expectf(t, r.ok, "close its own: %s", r.error)
	_, tab, _ = find_tab(mine)
	testing.expect(t, tab == nil, "closed")
	// the user's close rule holds for agents too: "always" asks the user
	mine = run_command(New_App_Tab{name = "fake"}, pi).created_id
	_, tab, _ = find_tab(mine)
	tab.status = .Running
	state.settings.confirm_close[tab_kind_id(tab.kind)] = .Always
	r = run_command(App_Close{tab_id = mine}, pi)
	testing.expectf(t, !r.ok && r.error == "needs_confirmation" && r.confirm_by_user, "asks the user: %v", r)
	_, tab, _ = find_tab(mine)
	testing.expect(t, tab != nil, "still open until the user confirms")
}

// A read-only Claude chat reads apps but opens, restarts and closes none.
@(test)
app_open_refused_read_only_claude :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	sa := find_session(a)
	cl_id := new_id()
	append(&sa.tabs, Tab{id = cl_id, kind = Claude_Tab{readonly = true}, title = "claude", status = .Running})
	ro := Caller{kind = .Panel, tab_id = cl_id, claude = true}
	mine := run_command(New_App_Tab{name = "fake"}, {kind = .UI}).created_id
	for cmd in ([]Command{New_App_Tab{name = "fake"}, App_Restart{tab_id = mine}, App_Close{tab_id = mine}}) {
		r := run_command(cmd, ro)
		testing.expectf(t, !r.ok && strings.contains(r.error, "read-only"), "%s refused: %s", command_type(cmd), r.error)
	}
	r := run_command(App_Declared{}, ro)
	testing.expectf(t, r.ok, "it may still list them: %s", r.error)
}

// Home (control) is unchanged: argv or a command line, the session it names (none: the one on
// screen), the tab in front.
@(test)
app_open_home_unchanged :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, home, dir := ao_reset(t)
	defer ao_done(dir)
	atlas := Caller{kind = .Control, tab_id = ao_first(home)}
	r := run_command(New_App_Tab{session = a, argv = {AO_MISSING}}, atlas)
	testing.expectf(t, r.ok, "Home opens argv in a session it names: %s", r.error)
	testing.expect_value(t, state.current_session, a)
	testing.expect_value(t, find_session(a).active_tab, r.created_id)
	r = run_command(New_App_Tab{argv = {AO_MISSING}}, atlas)
	testing.expectf(t, r.ok, "no session: the one on screen: %s", r.error)
	s, _, _ := find_tab(r.created_id)
	testing.expect(t, s != nil && s.id == a, "the one on screen")
	r = run_command(New_App_Tab{session = b, name = "fake"}, atlas)
	testing.expectf(t, r.ok, "by name too: %s", r.error)
	_, tab, _ := find_tab(r.created_id)
	testing.expect(t, tab != nil && tab.title == "fake", "titled by its name")
	// its restart and close as before
	r = run_command(App_Restart{tab_id = r.created_id}, atlas)
	testing.expect_value(t, r.error, "could not start the app")
}

// A project's apps.json that is not the expected shape lists nothing (never a crash): an agent
// can write the file and then ask for it.
@(test)
app_declared_bad_file :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	path := strings.concatenate({find_session(a).cwd, "/.pi-desk/apps.json"}, context.temp_allocator)
	for bad in ([]string{`[1,2]`, `"apps"`, `{"apps":{"name":"x"}}`, `{"apps":[1,{"name":"x","argv":"sh"},{"name":"y","argv":[1]}]}`, `not json`}) {
		_ = os.write_entire_file(path, transmute([]u8)bad)
		r := run_command(App_Declared{}, pi)
		testing.expectf(t, r.ok && !strings.contains(r.data, `"name":"x"`), "%s: %s %s", bad, r.error, r.data)
		r = run_command(New_App_Tab{name = "x"}, pi)
		testing.expectf(t, !r.ok, "%s: nothing to open", bad)
	}
}

@(private = "file")
ao_write_apps :: proc(session: u64, text: string) {
	_ = os.write_entire_file(strings.concatenate({find_session(session).cwd, "/.pi-desk/apps.json"}, context.temp_allocator), transmute([]u8)text)
}

// A read-only chat's pi (started under Chats: read-only) opens, restarts and closes no apps.
@(test)
app_open_refused_read_only_chat :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	p := Project{id = new_id(), cwd = find_session(a).cwd, group = .Chats}
	append(&state.projects, p)
	find_session(a).project_id = p.id
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	mine := run_command(New_App_Tab{name = "fake"}, pi).created_id
	testing.expect(t, mine != 0, "chats full: it opens")
	find_session(a).tabs[0].kind = Pi_Tab{readonly = true} // started read-only (chat_env)
	for cmd in ([]Command{New_App_Tab{name = "fake"}, App_Restart{tab_id = mine}, App_Close{tab_id = mine}}) {
		r := run_command(cmd, pi)
		testing.expectf(t, !r.ok && strings.contains(r.error, "read-only"), "%s refused: %s", command_type(cmd), r.error)
	}
	r := run_command(App_Declared{}, pi)
	testing.expectf(t, r.ok, "listing is reading: %s", r.error)
}

// At most APP_AGENT_MAX app tabs an agent opened run per session, counting those still closing.
@(test)
app_open_capped_per_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, b, _, dir := ao_reset(t)
	defer ao_done(dir)
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	FAKE_PID :: posix.pid_t(1_000_000_000) // never a real pid (macOS stops at 99999)
	ids: [dynamic]u64
	defer delete(ids)
	for _ in 0 ..< APP_AGENT_MAX - 1 {
		id := run_command(New_App_Tab{name = "fake"}, pi).created_id
		testing.expect(t, id != 0, "opened")
		if p := app_of(id); p != nil do p.pid = FAKE_PID // as if running
		append(&ids, id)
	}
	// one closing (its process not gone yet) still counts
	closing := new(App_Proc)
	closing.tab_id, closing.session, closing.by_agent, closing.pid, closing.closing = 999_999, a, true, FAKE_PID, true
	append(&dying, closing)
	r := run_command(New_App_Tab{name = "fake"}, pi)
	testing.expectf(t, !r.ok && strings.contains(r.error, fmt.tprintf("%d", APP_AGENT_MAX)), "past the cap: %v", r)
	// the user's own opens and other sessions are not counted against it
	r = run_command(New_App_Tab{session = a, name = "fake"}, {kind = .UI})
	testing.expectf(t, r.ok, "the user's: %s", r.error)
	r = run_command(New_App_Tab{session = b, name = "fake"}, {kind = .Control})
	testing.expectf(t, r.ok, "another session: %s", r.error)
	// the closing one gone: room again
	pop(&dying)
	free(closing)
	r = run_command(New_App_Tab{name = "fake"}, pi)
	testing.expectf(t, r.ok, "room again: %s", r.error)
	for id in ids do if p := app_of(id); p != nil do p.pid = 0 // never signalled
}

// An agent's title (its own, or the apps.json name it gave) is one line of at most 80 characters
// with no control or bidi characters.
@(test)
app_open_agent_title_clean :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	long := strings.repeat("x", 200, context.temp_allocator)
	r := run_command(New_App_Tab{name = "fake", title = strings.concatenate({"ev\u202eil\nline\x1b[31m", long}, context.temp_allocator)}, pi)
	testing.expectf(t, r.ok, "%s", r.error)
	_, tab, _ := find_tab(r.created_id)
	if tab != nil {
		testing.expectf(t, strings.rune_count(tab.title) <= 80, "capped: %d", strings.rune_count(tab.title))
		for ch in tab.title do testing.expectf(t, ch >= 0x20 && ch != 0x7f && !rune_hidden(ch), "clean: %q", tab.title)
		testing.expect(t, strings.has_prefix(tab.title, "evil line"), tab.title)
	}
	// a name from apps.json gets the same
	mid := strings.repeat("y", 70, context.temp_allocator)
	ao_write_apps(a, fmt.tprintf(`{{"apps":[{{"name":"n\u2066ame\u0007%s","argv":[%q]}}]}}`, mid, AO_MISSING))
	r = run_command(New_App_Tab{name = fmt.tprintf("n\u2066ame\u0007%s", mid)}, pi)
	testing.expectf(t, r.ok, "%s", r.error)
	_, tab, _ = find_tab(r.created_id)
	if tab != nil do testing.expectf(t, strings.rune_count(tab.title) <= 80 && strings.has_prefix(tab.title, "name "), "%q", tab.title)
	// the user's own title is left as it is
	r = run_command(New_App_Tab{session = a, name = "fake", title = long}, {kind = .UI})
	_, tab, _ = find_tab(r.created_id)
	if tab != nil do testing.expect_value(t, len(tab.title), 200)
}

// apps.json over 256 KB is not read.
@(test)
app_declared_size_cap :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	pad := strings.repeat(" ", 300 * 1024, context.temp_allocator)
	ao_write_apps(a, fmt.tprintf(`{{"apps":[{{"name":"big","argv":[%q]}}]}}%s`, AO_MISSING, pad))
	r := run_command(App_Declared{}, Caller{kind = .Panel, tab_id = ao_first(a)})
	testing.expectf(t, r.ok && !strings.contains(r.data, "big"), "%s %s", r.error, r.data)
}

// Round 2. apps.json that is a symlink (to /dev/zero), a FIFO or a folder: nothing read, no hang.
@(test)
app_declared_not_a_regular_file :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	path := strings.concatenate({find_session(a).cwd, "/.pi-desk/apps.json"}, context.temp_allocator)
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	os.remove(path)
	posix.symlink("/dev/zero", cpath)
	r := run_command(App_Declared{}, pi)
	testing.expectf(t, r.ok && strings.contains(r.data, `"apps":[]`), "a symlink: %s", r.data)
	os.remove(path)
	posix.mkfifo(cpath, {.IRUSR, .IWUSR})
	r = run_command(App_Declared{}, pi)
	testing.expectf(t, r.ok && strings.contains(r.data, `"apps":[]`), "a FIFO: %s", r.data)
	r = run_command(New_App_Tab{name = "fake"}, pi)
	testing.expect(t, !r.ok, "nothing to open")
	os.remove(path)
}

// Round 2. A screenshot waiting on a hidden app that exits is answered (the last frame or
// no_frame), never left hanging.
@(test)
app_shot_wait_answered_when_the_app_exits :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	id := run_command(New_App_Tab{session = a, name = "fake"}, {kind = .UI}).created_id
	p := app_of(id)
	if !testing.expect(t, p != nil, "an app") do return
	p.pid = posix.pid_t(1_000_000_000) // never a real pid
	append(&p.shot_waits, Shot_Wait{request_id = 77, deadline = time.tick_add(time.tick_now(), time.Hour)})
	run_command(App_Restart{tab_id = id}, {kind = .UI}) // the old process goes (app_gone)
	testing.expect_value(t, len(p.shot_waits), 0)
	p.pid = 0
}

// Round 2. Restarting an exited app an agent opened counts against APP_AGENT_MAX too.
@(test)
app_restart_capped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	FAKE :: posix.pid_t(1_000_000_000)
	ids: [dynamic]u64
	defer delete(ids)
	for _ in 0 ..< APP_AGENT_MAX + 1 do append(&ids, run_command(New_App_Tab{name = "fake"}, pi).created_id)
	for id in ids[:APP_AGENT_MAX] do if p := app_of(id); p != nil do p.pid = FAKE
	exited := ids[APP_AGENT_MAX] // could not start: pid 0
	r := run_command(App_Restart{tab_id = exited}, pi)
	testing.expectf(t, !r.ok && strings.contains(r.error, fmt.tprintf("%d", APP_AGENT_MAX)), "restart past the cap: %v", r)
	for id in ids do if p := app_of(id); p != nil do p.pid = 0
}

// Round 2. Read-only is what the pi tab was started with (chat_env), not today's setting.
@(test)
app_open_read_only_as_started :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	p := Project{id = new_id(), cwd = find_session(a).cwd, group = .Chats}
	append(&state.projects, p)
	find_session(a).project_id = p.id
	pi := Caller{kind = .Panel, tab_id = ao_first(a)}
	// started read-only, the setting turned off since: still refused
	find_session(a).tabs[0].kind = Pi_Tab{readonly = true}
	state.settings.chats_readonly = false
	r := run_command(New_App_Tab{name = "fake"}, pi)
	testing.expectf(t, !r.ok && strings.contains(r.error, "read-only"), "%v", r)
	// started full, the setting turned on since: pi runs full, so it may
	find_session(a).tabs[0].kind = Pi_Tab{}
	state.settings.chats_readonly = true
	r = run_command(New_App_Tab{name = "fake"}, pi)
	testing.expectf(t, r.ok, "%s", r.error)
	testing.expect(t, chat_readonly(p.id), "a chat starts read-only now")
}

// pi-desk asks nothing: an agent's open of a declared entry runs at once, with the agent's own
// authority (docs/ENGINE-BRIDGE.md, trust model).
@(test)
app_open_never_asks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	ao_write_apps(a, fmt.tprintf(`{{"apps":[{{"name":"fresh","argv":[%q,"--new"]}}]}}`, AO_MISSING))
	sa := find_session(a)
	cl_id := new_id()
	append(&sa.tabs, Tab{id = cl_id, kind = Claude_Tab{}, title = "claude", status = .Running})
	for caller in ([]Caller{{kind = .Panel, tab_id = ao_first(a)}, {kind = .Panel, tab_id = cl_id, claude = true}}) {
		r := run_command(New_App_Tab{name = "fresh"}, caller)
		testing.expectf(t, r.ok && r.created_id != 0 && r.error != "needs_confirmation", "opened at once: %v", r)
	}
	testing.expect_value(t, len(state.pending_confirmations), 0)
	testing.expect(t, !strings.contains(workspace_json(), "app_approved"), "nothing saved")
}

// Names over 80 characters are not entries (an agent's title is never longer).
@(test)
app_declared_long_names_skipped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	a, _, _, dir := ao_reset(t)
	defer ao_done(dir)
	ao_write_apps(a, fmt.tprintf(`{{"apps":[{{"name":%q,"argv":[%q]}},{{"name":%q,"argv":[%q]}}]}}`, strings.repeat("z", 81, context.temp_allocator), AO_MISSING, strings.repeat("y", 80, context.temp_allocator), AO_MISSING))
	es := app_entries(find_session(a).cwd)
	testing.expectf(t, len(es) == 1 && strings.rune_count(es[0].name) == 80, "%v", es)
}
