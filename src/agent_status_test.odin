package main

// Agent status for every terminal tab (agent_status.odin): OSC 7501 records
// (replace, clear, nesting, app inheritance, bounds, eviction, ending at a
// prompt or exit), the tab's summary, precedence (bridge > OSC 7501),
// unseen (done while not looking, seen on focus, Mark unread), roll-ups and
// the attention sort, the tooltip line and the snapshot. Same rules as
// core_test.odin: shared global State, one thread; no processes except one
// test that drives a real libghostty-vt terminal (no child).

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import "core"
import gh "ghostty"

@(private = "file")
as_rep :: proc(state: core.Prog_State, id := "", app := "", msg := "", kind := core.Prog_Kind.None, title := "") -> core.Prog_Report {
	return {state = state, id = id, app = app, msg = msg, kind = kind, title = title, progress = -1}
}

@(test)
prog_records_replace_clear_nest :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r: core.Prog_Records
	defer core.prog_free(&r)
	core.prog_apply(&r, as_rep(.Working, app = "deploy", msg = "rolling out"))
	core.prog_apply(&r, as_rep(.Working, id = "us-east"))
	core.prog_apply(&r, as_rep(.Blocked, id = "us-east/db", kind = .Permission, msg = "Migrate?"))
	testing.expect_value(t, len(r.list), 3)
	testing.expect(t, r.dirty)
	// the most urgent: the blocked child, its app from the root (nearest ancestor with one)
	s := core.prog_summary(&r)
	testing.expect_value(t, s.state, core.Prog_State.Blocked)
	testing.expect_value(t, s.kind, core.Prog_Kind.Permission)
	testing.expect_value(t, s.app, "deploy")
	testing.expect_value(t, s.id, "us-east/db")
	testing.expect_value(t, s.msg, "Migrate?")
	testing.expect_value(t, s.records, 3)
	// a report replaces its record completely: msg and kind are gone
	core.prog_apply(&r, as_rep(.Working, id = "us-east/db"))
	s = core.prog_summary(&r)
	testing.expect_value(t, s.state, core.Prog_State.Working)
	testing.expect_value(t, s.kind, core.Prog_Kind.None)
	testing.expect_value(t, len(r.list), 3)
	// ties: the latest
	testing.expect_value(t, s.id, "us-east/db")
	// clear "us-east" takes "us-east/db" too, not "us-eastern"
	core.prog_apply(&r, as_rep(.Done, id = "us-eastern"))
	core.prog_apply(&r, {clear = true, id = "us-east"})
	testing.expect_value(t, len(r.list), 2)
	for x in r.list do testing.expect(t, x.id == "" || x.id == "us-eastern", x.id)
	// a kind only goes with blocked; progress out of range is none
	core.prog_apply(&r, {state = .Working, kind = .Auth, progress = 101})
	testing.expect_value(t, r.list[0].kind, core.Prog_Kind.None)
	testing.expect_value(t, r.list[0].progress, i8(-1))
	core.prog_apply(&r, {state = .Working, progress = 40})
	testing.expect_value(t, r.list[0].progress, i8(40))
	// clear with no id: every record
	core.prog_apply(&r, {clear = true})
	testing.expect_value(t, len(r.list), 0)
	testing.expect_value(t, core.prog_summary(&r).state, core.Prog_State.None)
}

@(test)
prog_records_bounds :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r: core.Prog_Records
	defer core.prog_free(&r)
	// at most PROG_RECORDS_MAX: the one updated longest ago goes
	for i in 0 ..< core.PROG_RECORDS_MAX + 10 do core.prog_apply(&r, as_rep(.Working, id = fmt.tprintf("job/%d", i)))
	testing.expect_value(t, len(r.list), core.PROG_RECORDS_MAX)
	has :: proc(r: ^core.Prog_Records, id: string) -> bool {
		for x in r.list do if x.id == id do return true
		return false
	}
	testing.expect(t, !has(&r, "job/0") && !has(&r, "job/9"), "oldest dropped")
	testing.expect(t, has(&r, "job/10") && has(&r, fmt.tprintf("job/%d", core.PROG_RECORDS_MAX + 9)))
	// refreshing an old one keeps it
	core.prog_apply(&r, as_rep(.Done, id = "job/10"))
	core.prog_apply(&r, as_rep(.Working, id = "new"))
	testing.expect(t, has(&r, "job/10") && !has(&r, "job/11"))
	// untrusted text: cut at a character boundary, one line, no bidi or invisible characters
	long := strings.repeat("é", 1000, context.temp_allocator)
	core.prog_apply(&r, as_rep(.Blocked, id = strings.repeat("x", 500, context.temp_allocator), app = long, msg = long, title = long))
	last := r.list[len(r.list) - 1]
	testing.expect(t, len(last.id) <= core.PROG_ID_MAX && len(last.app) <= core.PROG_APP_MAX && len(last.msg) <= core.PROG_MSG_MAX && len(last.title) <= core.PROG_TITLE_MAX)
	testing.expect(t, utf8.valid_string(last.msg) && utf8.valid_string(last.app), "cut at a boundary")
	core.prog_apply(&r, as_rep(.Blocked, id = "spoof", msg = "ok‮gnp.exe​\nnext"))
	for x in r.list do if x.id == "spoof" do testing.expect_value(t, x.msg, "okgnp.exe next")
}

@(test)
prog_records_end_live :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	r: core.Prog_Records
	defer core.prog_free(&r)
	core.prog_apply(&r, as_rep(.Working))
	core.prog_apply(&r, as_rep(.Blocked, id = "a"))
	core.prog_apply(&r, as_rep(.Idle, id = "b"))
	core.prog_apply(&r, as_rep(.Done, id = "c"))
	core.prog_apply(&r, as_rep(.Error, id = "d"))
	testing.expect(t, core.prog_live(&r))
	r.dirty = false
	// a prompt or an exit: working, blocked and idle go; done and error stay until seen
	core.prog_end_live(&r)
	testing.expect(t, r.dirty)
	testing.expect(t, !core.prog_live(&r))
	testing.expect_value(t, len(r.list), 2)
	testing.expect_value(t, core.prog_summary(&r).state, core.Prog_State.Error)
	core.prog_reset(&r)
	testing.expect_value(t, len(r.list), 0)
}

// One session with a pi tab (bridge unknown) and a shell tab running a
// program that reports; a second session, current. Window in front.
@(private = "file")
as_reset :: proc() -> (a, b, a_pi, a_sh: u64) {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{}
	app.window_active = true
	core.platform = {notify = proc(title, body: string) {}}
	win_os = {}
	p := core.Project{id = core.new_id(), group = .Projects, cwd = "/tmp/as-proj", label = "as-proj"}
	append(&state.projects, p)
	state.selected_project = p.id
	for name, i in ([]string{"alpha", "beta"}) {
		s := core.Open_Session{id = core.new_id(), project_id = p.id, pi_session_id = fmt.aprintf("pi-%s", name), cwd = "/tmp/as-proj", shown_at = i64(10 - i)}
		append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running})
		append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Shell_Tab{}, title = "shell 1", status = .Running})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
		if i == 0 {
			a, a_pi, a_sh = s.id, s.tabs[0].id, s.tabs[1].id
		} else do b = s.id
	}
	state.current_session = b
	return
}

@(private = "file")
as_done :: proc() {core.platform, win_os = {}, {}}

// What pump_all would send after the terminal's records changed.
@(private = "file")
as_report :: proc(tab: u64, reps: ..core.Prog_Report) {
	r: core.Prog_Records
	defer core.prog_free(&r)
	for x in reps do core.prog_apply(&r, x)
	core.run_command(core.Program_Status{tab_id = tab, summary = core.prog_summary(&r)})
}

@(test)
status_unseen_and_bell :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	a, b, _, a_sh := as_reset()
	defer as_done()
	_, sh, _ := core.find_tab(a_sh)
	// working, then blocked: the row waits; the bell has it (not on screen)
	as_report(a_sh, as_rep(.Working, app = "claude-code"))
	testing.expect_value(t, core.session_status("pi-alpha"), core.Row_Status.Running)
	as_report(a_sh, as_rep(.Blocked, app = "claude-code", kind = .Permission, msg = "Edit main.odin?"))
	testing.expect_value(t, core.session_status("pi-alpha"), core.Row_Status.Waiting)
	testing.expect_value(t, len(state.notices.items), 1)
	testing.expect_value(t, state.notices.items[0].kind, core.Notice_Kind.Waiting)
	testing.expect_value(t, state.notices.items[0].tab_id, a_sh)
	// done in the background: unseen, a Finished entry
	as_report(a_sh, as_rep(.Done, app = "claude-code"))
	testing.expect(t, sh.unseen)
	testing.expect_value(t, core.tab_status_view(sh^).dot, core.Row_Status.Unseen)
	testing.expect_value(t, core.session_status("pi-alpha"), core.Row_Status.Unseen)
	// looking at the session shows its pi tab: the shell stays unseen
	core.run_command(core.Focus_Session{session = a}, {kind = .UI})
	testing.expect(t, sh.unseen)
	// its tab: seen
	core.run_command(core.Focus_Tab{tab_id = a_sh}, {kind = .UI})
	testing.expect(t, !sh.unseen)
	testing.expect_value(t, core.session_status("pi-alpha"), core.Row_Status.None)
	// on screen when it finishes: never unseen
	as_report(a_sh, as_rep(.Working))
	as_report(a_sh, as_rep(.Idle))
	testing.expect(t, !sh.unseen)
	// the window behind: unseen; coming to the front (status_wants_seen) reads it
	app.window_active = false
	as_report(a_sh, as_rep(.Working))
	as_report(a_sh, as_rep(.Idle))
	testing.expect(t, sh.unseen)
	core.run_command(core.Focus_Session{session = a}, {kind = .UI}) // the window is still behind: not seen
	testing.expect(t, sh.unseen)
	app.window_active = true
	testing.expect_value(t, len(core.status_wants_seen()), 1)
	testing.expect_value(t, core.status_wants_seen()[0], a_sh)
	core.run_command(core.Set_Unread{tab_id = a_sh, unread = false}, {kind = .Internal})
	testing.expect(t, !sh.unseen)
	testing.expect_value(t, len(core.status_wants_seen()), 0)
	// working again clears a Mark unread
	core.run_command(core.Focus_Session{session = b}, {kind = .UI})
	core.run_command(core.Set_Unread{tab_id = a_sh, unread = true}, {kind = .UI})
	testing.expect(t, sh.unseen)
	as_report(a_sh, as_rep(.Working))
	testing.expect(t, !sh.unseen)
	// an error: red, an entry
	n := len(state.notices.items)
	as_report(a_sh, as_rep(.Error, msg = "boom"))
	testing.expect_value(t, core.session_status("pi-alpha"), core.Row_Status.Error)
	testing.expect_value(t, len(state.notices.items) >= n, true)
	testing.expect_value(t, state.notices.items[len(state.notices.items) - 1].kind, core.Notice_Kind.Error)
	// a cleared record: no status
	core.run_command(core.Program_Status{tab_id = a_sh})
	testing.expect_value(t, core.tab_status_view(sh^).source, core.Status_Source.None)
}

@(test)
status_bridge_precedence :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	a, _, a_pi, a_sh := as_reset()
	defer as_done()
	_, pt, _ := core.find_tab(a_pi)
	// no bridge: a pi tab's own OSC 7501 counts
	as_report(a_pi, as_rep(.Working, app = "pi"))
	v := core.tab_status_view(pt^)
	testing.expect_value(t, v.source, core.Status_Source.Osc7501)
	testing.expect_value(t, v.dot, core.Row_Status.Running)
	// the bridge reports: it wins
	core.run_command(core.Pi_Status_Update{tab_id = a_pi, agent = .Idle}, {kind = .Panel, tab_id = a_pi})
	v = core.tab_status_view(pt^)
	testing.expect_value(t, v.source, core.Status_Source.Bridge)
	testing.expect_value(t, v.dot, core.Row_Status.None)
	testing.expect(t, v.at != {}, "when the bridge reported")
	// and its OSC 7501 transitions make no entries
	n := len(state.notices.items)
	as_report(a_pi, as_rep(.Blocked))
	testing.expect_value(t, len(state.notices.items), n)
	testing.expect_value(t, core.tab_status_view(pt^).dot, core.Row_Status.None)
	// the bridge's run ending in the background: unseen (the bell's Finished too)
	core.run_command(core.Pi_Status_Update{tab_id = a_pi, agent = .Working}, {kind = .Panel, tab_id = a_pi})
	core.run_command(core.Pi_Status_Update{tab_id = a_pi, agent = .Idle}, {kind = .Panel, tab_id = a_pi})
	testing.expect(t, pt.unseen)
	testing.expect_value(t, core.tab_status_view(pt^).dot, core.Row_Status.Unseen)
	// a waiting shell outranks an unseen pi tab in the row
	as_report(a_sh, as_rep(.Blocked))
	st, from := core.session_row_status(core.find_session(a))
	testing.expect_value(t, st, core.Row_Status.Waiting)
	testing.expect_value(t, from.id, a_sh)
	// the tooltip names the tab that gave the row its dot, and the source
	line := core.session_explain(core.find_session(a))
	testing.expectf(t, strings.has_prefix(line, "shell 1: program: waiting for you · OSC 7501"), "%q", line)
	testing.expectf(t, strings.has_prefix(core.status_explain(pt^), "pi: finished, not seen yet · pi bridge"), "%q", core.status_explain(pt^))
	_, sh, _ := core.find_tab(a_sh)
	sh.title = "x"
	core.run_command(core.Program_Status{tab_id = a_sh})
	testing.expect_value(t, core.status_explain(sh^), "")
}

@(test)
status_mark_unread :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	a, b, a_pi, a_sh := as_reset()
	defer as_done()
	// marks the session's active tab (its pi tab)
	r := core.run_command(core.Set_Unread{pi_session_id = "pi-alpha", unread = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	_, pt, _ := core.find_tab(a_pi)
	testing.expect(t, pt.unseen)
	testing.expect_value(t, core.session_status("pi-alpha"), core.Row_Status.Unseen)
	// read clears every tab
	_, sh, _ := core.find_tab(a_sh)
	sh.unseen = true
	core.run_command(core.Set_Unread{pi_session_id = "pi-alpha", unread = false}, {kind = .UI})
	testing.expect(t, !pt.unseen && !sh.unseen)
	// unread again, then looking at it reads it
	core.run_command(core.Set_Unread{pi_session_id = "pi-alpha", unread = true}, {kind = .Control})
	core.run_command(core.Focus_Session{session = a}, {kind = .UI})
	testing.expect(t, !pt.unseen)
	// the session on screen may be marked: it stays until looked at again
	core.run_command(core.Set_Unread{pi_session_id = "pi-alpha", unread = true}, {kind = .UI})
	testing.expect(t, pt.unseen)
	core.run_command(core.Focus_Session{session = b}, {kind = .UI})
	core.run_command(core.Focus_Session{session = a}, {kind = .UI})
	testing.expect(t, !pt.unseen)
	// errors
	testing.expect_value(t, core.run_command(core.Set_Unread{pi_session_id = "nope", unread = true}, {kind = .UI}).error, "the session is not open")
	testing.expect_value(t, core.run_command(core.Set_Unread{unread = true}, {kind = .UI}).error, "give tab_id or pi_session_id")
	testing.expect_value(t, core.run_command(core.Set_Unread{tab_id = 99999, unread = true}, {kind = .UI}).error, "no such tab")
	// a pi tab's bridge may not (not a report)
	testing.expect(t, !core.run_command(core.Set_Unread{tab_id = a_pi, unread = true}, {kind = .Panel, tab_id = a_pi}).ok)
	// over the wire
	cmd, err := core.parse_command(`{"type":"set_unread","pi_session_id":"pi-alpha","unread":true}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect(t, core.run_command(cmd, {kind = .Script}).ok)
	// the row menu offers it for an open session, both ways
	menu_open(Menu_Session{project_id = state.selected_project, pi_session_id = "pi-alpha"}, {})
	defer menu_close()
	labels := make([dynamic]string, context.temp_allocator)
	for it in menu_items() do append(&labels, it.label)
	found := false
	for l in labels do if l == "Mark as read" do found = true
	testing.expectf(t, found, "menu: %v", labels)
}

@(test)
status_rollup_and_attention_sort :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	a, b, a_pi, a_sh := as_reset()
	defer as_done()
	// a third and fourth session in the project
	pid := state.selected_project
	ids: [2]u64
	for name, i in ([]string{"gamma", "delta"}) {
		s := core.Open_Session{id = core.new_id(), project_id = pid, pi_session_id = fmt.aprintf("pi-%s", name), cwd = "/tmp/as-proj", shown_at = i64(20 + i)}
		append(&s.tabs, core.Tab{id = core.new_id(), kind = core.Pi_Tab{}, title = "pi", status = .Running})
		s.active_tab = s.tabs[0].id
		append(&state.open_sessions, s)
		ids[i] = s.tabs[0].id
	}
	// alpha: blocked (shell); beta: working; gamma: done unseen; delta: idle
	as_report(a_sh, as_rep(.Blocked))
	_, _, beta_pi := a, b, core.find_session(b).tabs[0].id
	core.run_command(core.Pi_Status_Update{tab_id = beta_pi, agent = .Working}, {kind = .Panel, tab_id = beta_pi})
	core.run_command(core.Set_Unread{tab_id = ids[0], unread = true}, {kind = .UI})
	_ = a_pi
	testing.expect_value(t, core.project_status(pid), core.Row_Status.Waiting)
	core.run_command(core.Set_Sort{section = .Sessions, by = .Attention}, {kind = .UI})
	titles := make([dynamic]string, context.temp_allocator)
	for r in core.sidebar_sessions(.Sessions) do append(&titles, r.session.id)
	testing.expectf(t, len(titles) == 4 && titles[0] == "pi-alpha" && titles[1] == "pi-gamma" && titles[2] == "pi-beta" && titles[3] == "pi-delta", "attention order: %v", titles)
	// recent order is unchanged by status (newest shown first)
	core.run_command(core.Set_Sort{section = .Sessions, by = .Recent}, {kind = .UI})
	clear(&titles)
	for r in core.sidebar_sessions(.Sessions) do append(&titles, r.session.id)
	testing.expectf(t, titles[0] == "pi-delta", "recent order: %v", titles)
	// pins still come first
	append(&state.sidebar.pinned_sessions, strings.clone("pi-delta"))
	core.run_command(core.Set_Sort{section = .Sessions, by = .Attention}, {kind = .UI})
	testing.expect_value(t, core.sidebar_sessions(.Sessions)[0].session.id, "pi-delta")
	// the project row rolls up: waiting wins; without it, unseen outranks working
	core.run_command(core.Program_Status{tab_id = a_sh})
	testing.expect_value(t, core.project_status(pid), core.Row_Status.Unseen)
	// the wire name
	cmd, err := core.parse_command(`{"type":"set_sort","section":"projects","by":"attention"}`, context.temp_allocator)
	testing.expect_value(t, err, "")
	testing.expect(t, core.run_command(cmd, {kind = .Script}).ok)
	testing.expect_value(t, state.sidebar.sort[.Projects], core.Sort_By.Attention)
	// and it is in the sort menu
	menu_open(Menu_Sort(.Sessions), {})
	defer menu_close()
	found := false
	for it in menu_items() do if it.label == "Needs attention" do found = true
	testing.expect(t, found, "sort menu lists Needs attention")
}

@(test)
status_snapshot :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	_, _, a_pi, a_sh := as_reset()
	defer as_done()
	as_report(a_sh, as_rep(.Blocked, app = "claude-code", kind = .Question, msg = "Which \"file\"?"))
	js := core.state_json()
	testing.expect(t, strings.contains(js, `"agent_status":"waiting"`), "session roll-up")
	testing.expect(t, strings.contains(js, `"agent_status":{"dot":"waiting","source":"osc7501","unseen":false,"at":`), "tab")
	testing.expect(t, strings.contains(js, `"osc7501":{"state":"blocked","kind":"question","app":"claude-code","message":"Which \"file\"?","records":1,"at":`), js)
	_ = a_pi
	// the event names the state, never the message
	ev := core.command_json(core.Program_Status{tab_id = a_sh, summary = {state = .Blocked, msg = "secret-ish"}}, true)
	testing.expect(t, !strings.contains(ev, "secret-ish"), ev)
	testing.expect(t, strings.contains(ev, `"state":"blocked"`), ev)
}

// A real libghostty-vt terminal (no child): the support query is answered,
// reports land in the Term's records, a prompt (OSC 133 A) ends them, and
// status_pump hands the tab its summary.
As_Reply :: struct {
	buf: [dynamic]u8,
}
@(private = "file")
as_reply: As_Reply

@(test)
status_terminal_end_to_end :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	_, _, _, a_sh := as_reset()
	defer as_done()
	core.app_context = context // the callbacks run in it
	term := new(core.Term)
	defer {
		core.term_free(term)
		free(term)
	}
	testing.expect(t, core.term_init(term, 40, 4))
	core.status_fg = proc(p: ^core.Pty) -> i32 {return 5000} // a program (not the shell) in the foreground
	defer core.status_fg = core.pty_foreground_pgrp
	clear(&as_reply.buf)
	capture :: proc "c" (gt: gh.Terminal, ud: rawptr, data: [^]u8, n: c.size_t) {
		context = runtime.default_context()
		append(&as_reply.buf, ..data[:n])
	}
	gh.terminal_set(term.gt, .Write_Pty, rawptr(capture)) // no pty here
	w :: proc(term: ^core.Term, s: string) {gh.terminal_vt_write(term.gt, raw_data(s), len(s))}
	w(term, "\x1b]7501;?\x1b\\")
	testing.expectf(t, strings.has_prefix(string(as_reply.buf[:]), "\x1b]7501;?:states="), "reply %q", string(as_reply.buf[:]))
	w(term, "\x1b]7501;state=working:app=claude-code\x07")
	w(term, "\x1b]7501;state=blocked:id=sub/1:kind=auth:msg=VG9rZW4/\x07") // "Token?"
	w(term, "\x1b]7501;state=bogus\x07") // dropped by libghostty-vt
	testing.expect_value(t, len(term.prog.list), 2)
	term.running = true
	core.status_pump(a_sh, term)
	_, sh, _ := core.find_tab(a_sh)
	testing.expect_value(t, sh.prog.state, core.Prog_State.Blocked)
	testing.expect_value(t, sh.prog.kind, core.Prog_Kind.Auth)
	testing.expect_value(t, sh.prog.app, "claude-code") // inherited from the root
	testing.expect_value(t, sh.prog.msg, "Token?")
	testing.expect_value(t, sh.prog.records, 2)
	// nothing new: no command
	v := state.version
	core.status_pump(a_sh, term)
	testing.expect_value(t, state.version, v)
	// a new shell prompt ends working and blocked
	w(term, "\x1b]133;A\x07")
	core.status_pump(a_sh, term)
	testing.expect_value(t, sh.prog.state, core.Prog_State.None)
	// done survives the program's exit
	w(term, "\x1b]7501;state=working\x07")
	w(term, "\x1b]7501;state=done:id=x\x07")
	term.running = false
	core.status_pump(a_sh, term)
	testing.expect_value(t, sh.prog.state, core.Prog_State.Done)
	testing.expect_value(t, sh.prog.records, 1)
	// RIS clears everything
	w(term, "\x1bc")
	core.status_pump(a_sh, term)
	testing.expect_value(t, sh.prog.state, core.Prog_State.None)
	// an oversized message is cut (libghostty-vt decodes; we bound)
	big := strings.repeat("QUFB", 2000, context.temp_allocator) // "AAA" x 2000
	w(term, fmt.tprintf("\x1b]7501;state=error:msg=%s\x07", big))
	term.running = true
	core.status_pump(a_sh, term)
	testing.expect(t, len(sh.prog.msg) <= core.PROG_MSG_MAX, "message bounded")
	core.prog_summary_free(&sh.prog)
	_ = time.Second
}

// ---- review round 1 ----

@(private = "file")
as_fg: i32
@(private = "file")
as_fake_fg :: proc(p: ^core.Pty) -> i32 {return as_fg}

// A terminal (no child) for tab_id with a fake shell pid; stubs the
// foreground lookup. Returns the term (in `terms`) and a cleanup.
@(private = "file")
as_term :: proc(t: ^testing.T, tab_id: u64, pid: i32) -> ^core.Term {
	core.app_context = context
	term := new(core.Term)
	testing.expect(t, core.term_init(term, 40, 4))
	gh.terminal_set(term.gt, .Write_Pty, nil) // no pty: no replies
	term.running = true
	term.pty.pid = pid
	core.terms[tab_id] = term
	core.status_fg = as_fake_fg
	as_exe = "/bin/bash" // macOS's /bin/sh runs as bash
	core.status_exe = proc(p: ^core.Pty) -> string {return as_exe}
	return term
}

@(private = "file")
as_term_done :: proc() {
	for _, x in core.terms {
		x.pty.pid = 0
		core.term_free(x)
		free(x)
	}
	clear(&core.terms)
	core.status_fg = core.pty_foreground_pgrp
	core.status_exe = core.pty_child_exe
}

@(private = "file")
as_w :: proc(term: ^core.Term, s: string) {gh.terminal_vt_write(term.gt, raw_data(s), len(s))}

// MUST-FIX 1: a report read after its program already exited (`cat log`):
// the shell owns the foreground, so nothing runs that could be blocked.
@(test)
status_report_after_program_exit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	_, _, a_pi, a_sh := as_reset()
	defer as_done()
	defer as_term_done()
	sh_term := as_term(t, a_sh, 4242)
	as_fg = 4242 // the shell itself is in the foreground
	as_w(sh_term, "\x1b]7501;state=blocked:kind=permission:app=spoof\x07")
	core.status_pump(a_sh, sh_term)
	_, sh, _ := core.find_tab(a_sh)
	testing.expect_value(t, core.tab_status_view(sh^).dot, core.Row_Status.None)
	// unknown foreground (0): same
	as_fg = 0
	as_w(sh_term, "\x1b]7501;state=working\x07")
	core.status_pump(a_sh, sh_term)
	testing.expect_value(t, core.tab_status_view(sh^).dot, core.Row_Status.None)
	// a program in the foreground keeps its report
	as_fg = 5000
	as_w(sh_term, "\x1b]7501;state=working\x07")
	core.status_pump(a_sh, sh_term)
	testing.expect_value(t, core.tab_status_view(sh^).dot, core.Row_Status.Running)
	// a pi tab's own process may report (its pid is pi's, not a shell's)
	pi_term := as_term(t, a_pi, 7777)
	as_fg = 7777
	as_w(pi_term, "\x1b]7501;state=working\x07")
	core.status_pump(a_pi, pi_term)
	_, pt, _ := core.find_tab(a_pi)
	testing.expect_value(t, core.tab_status_view(pt^).dot, core.Row_Status.Running)
}

// SHOULD-FIX 2: done/error go once the program left and the tab was seen.
@(test)
status_error_goes_after_exit_and_seen :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	_, _, _, a_sh := as_reset()
	defer as_done()
	defer as_term_done()
	term := as_term(t, a_sh, 4242)
	as_fg = 5000
	as_w(term, "\x1b]7501;state=working\x07")
	core.status_pump(a_sh, term)
	as_w(term, "\x1b]7501;state=error\x07")
	core.status_pump(a_sh, term)
	_, sh, _ := core.find_tab(a_sh)
	testing.expect_value(t, core.tab_status_view(sh^).dot, core.Row_Status.Error)
	// the program exits (the shell is back): still red, nobody saw it
	as_fg = 4242
	term.prog.checked = {}
	core.status_pump(a_sh, term)
	testing.expect_value(t, core.tab_status_view(sh^).dot, core.Row_Status.Error)
	// the user looks at it: gone
	core.run_command(core.Focus_Tab{tab_id = a_sh}, {kind = .UI})
	core.status_pump(a_sh, term)
	testing.expect_value(t, core.tab_status_view(sh^).dot, core.Row_Status.None)
	testing.expect_value(t, core.tab_status_view(sh^).source, core.Status_Source.None)
}

// SHOULD-FIX 3: the Running chip keeps a session whose pi works, though
// another of its tabs is unseen (stronger by rank).
@(test)
status_quick_filter_sees_working :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	a, _, a_pi, a_sh := as_reset()
	defer as_done()
	core.run_command(core.Pi_Status_Update{tab_id = a_pi, agent = .Working}, {kind = .Panel, tab_id = a_pi})
	core.run_command(core.Set_Unread{tab_id = a_sh, unread = true}, {kind = .UI})
	st, _ := core.session_row_status(core.find_session(a))
	testing.expect_value(t, st, core.Row_Status.Unseen)
	state.sidebar.only_running = true
	defer state.sidebar.only_running = false
	found := false
	for r in core.sidebar_sessions(.Sessions) do if r.session.id == "pi-alpha" do found = true
	testing.expect(t, found, "sessions list keeps it")
	found = false
	for s in core.sidebar_open() do if s.pi_session_id == "pi-alpha" do found = true
	testing.expect(t, found, "Open group keeps it")
}

// SHOULD-FIX 4: the same report again is not a new event.
@(test)
status_same_report_one_event :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	_, _, _, a_sh := as_reset()
	defer as_done()
	defer as_term_done()
	term := as_term(t, a_sh, 4242)
	as_fg = 5000
	n := core.status_events
	as_w(term, "\x1b]7501;state=working:msg=SGk=\x07")
	core.status_pump(a_sh, term)
	v := state.version
	as_w(term, "\x1b]7501;state=working:msg=SGk=\x07")
	core.status_pump(a_sh, term)
	as_w(term, "\x1b]7501;state=working:msg=SGk=\x07")
	core.status_pump(a_sh, term)
	testing.expect_value(t, core.status_events - n, 1)
	testing.expect_value(t, state.version, v)
	// a different message is
	as_w(term, "\x1b]7501;state=working:msg=SG8=\x07")
	core.status_pump(a_sh, term)
	testing.expect_value(t, core.status_events - n, 2)
}

// POLISH 5: a shell with only a done record still shows its output dot.
@(test)
status_output_dot_after_done :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	_, _, _, a_sh := as_reset()
	defer as_done()
	defer as_term_done()
	term := as_term(t, a_sh, 4242)
	as_fg = 5000
	core.run_command(core.Focus_Tab{tab_id = a_sh}, {kind = .UI}) // on screen: the done is seen
	as_w(term, "\x1b]7501;state=done\x07")
	core.status_pump(a_sh, term)
	term.last_output = time.tick_now()
	core.tab_term_facts_tick(time.tick_now()) // into the tab's record, which the window reads
	_, sh, _ := core.find_tab(a_sh)
	testing.expectf(t, core.tab_status_view(sh^).dot == .None, "view %v", core.tab_status_view(sh^))
	testing.expect_value(t, tab_strip_status(sh^, true), core.Row_Status.Running)
}

// POLISH 6: only terminal tabs are marked unread.
@(test)
status_unread_terminal_tabs_only :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	a, _, a_pi, _ := as_reset()
	defer as_done()
	s := core.find_session(a)
	ed := core.Tab{id = core.new_id(), kind = core.Editor_Tab{path = "/tmp/x.txt"}, title = "x.txt", status = .Running}
	append(&s.tabs, ed)
	s.active_tab = ed.id
	testing.expect(t, !core.run_command(core.Set_Unread{tab_id = ed.id, unread = true}, {kind = .UI}).ok, "an editor tab")
	testing.expect(t, core.run_command(core.Set_Unread{pi_session_id = "pi-alpha", unread = true}, {kind = .UI}).ok)
	_, et, _ := core.find_tab(ed.id)
	_, pt, _ := core.find_tab(a_pi)
	testing.expect(t, !et.unseen && pt.unseen, "its pi tab instead")
}

// After the dead-tab merge: a dead pi tab shows exited (its Restart bar says
// so), not the unseen dot it had; its live OSC 7501 records went at exit.
@(test)
status_dead_pi_tab_shows_exited :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	a, _, a_pi, _ := as_reset()
	defer as_done()
	_, pt, _ := core.find_tab(a_pi)
	pt.unseen = true
	testing.expect_value(t, core.tab_status_view(pt^).dot, core.Row_Status.Unseen)
	pt.status = .Exited
	testing.expect_value(t, core.tab_status_view(pt^).dot, core.Row_Status.Exited)
	st, _ := core.session_row_status(core.find_session(a))
	testing.expect_value(t, st, core.Row_Status.Exited)
}

// Round 2: `exec` into an agent keeps the shell's pid (its own process
// group): while the pid no longer runs the shell, its reports stand.
@(private = "file")
as_exe: string
@(test)
status_exec_into_agent :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator() // State and `terms` outlive the test
	_, _, _, a_sh := as_reset()
	defer as_done()
	defer as_term_done()
	term := as_term(t, a_sh, 4242)
	as_fg = 4242 // the tab's own pid holds the foreground
	as_exe = "/opt/agent/bin/claude" // exec'd
	as_w(term, "\x1b]7501;state=working\x07")
	core.status_pump(a_sh, term)
	_, sh, _ := core.find_tab(a_sh)
	testing.expect_value(t, core.tab_status_view(sh^).dot, core.Row_Status.Running)
	// still the shell (a report read after its program exited): dropped
	as_exe = "/bin/zsh"
	as_w(term, "\x1b]7501;state=blocked\x07")
	core.status_pump(a_sh, term)
	testing.expect_value(t, core.tab_status_view(sh^).dot, core.Row_Status.None)
	testing.expect(t, core.is_shell_exe("/bin/sh") && core.is_shell_exe("/opt/homebrew/bin/fish") && !core.is_shell_exe("/usr/local/bin/node") && !core.is_shell_exe("") && !core.is_shell_exe("/usr/bin/claude"))
}
