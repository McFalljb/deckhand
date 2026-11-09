package core

// Agent status for every terminal tab (docs/PROTOCOL.md §5 "Status dots").
//
// Two sources say what the program in a tab is doing:
//   - the pi bridge (pi.status, §4): pi tabs only;
//   - OSC 7501, the program status protocol
//     (https://www.superlogical.com/rex/docs/build/program-status): any
//     terminal tab. libghostty-vt parses and checks the reports and answers
//     the support query `OSC 7501 ; ?` while our callback is set (term.odin
//     registers it on every terminal); Claude Code reports only after that
//     answer.
//
// Precedence, per tab: the bridge while it reports (a pi tab whose agent is
// not unknown) > OSC 7501 > none. A session's row shows the strongest status
// of its tabs (status_rank), a project's row the strongest of its open
// sessions.
//
// OSC 7501 records live on the Term (runtime, at most PROG_RECORDS_MAX, the
// longest-unchanged one dropped first); pump_all hands the tab a summary (the
// most urgent record) through the internal program_status command, so State
// still only changes in run_command and subscribers see an event. Records
// follow the spec: a report replaces its record; clear removes it and those
// under it ("a" takes "a/b"); a record without an app takes its nearest
// ancestor's. working, blocked and idle records go when their program is gone
// (status_owner_gone: a new prompt, OSC 133 A; a shell tab's shell back in the
// foreground; the reporter left the foreground; the process exited); done and
// error stay until the user has seen the tab, then go too.
//
// "Done, not seen yet" (Tab.unseen): a tab whose program went from working or
// blocked to idle or done (OSC 7501), or whose pi went from working to idle
// (bridge), while the user was not looking at it: not the current session's
// active tab, or the window behind (the bell's rule, notify.odin). It clears
// when the user looks at the tab (focus_session, the window coming to the
// front, a closed tab handing over), when the program starts working again,
// or with set_unread false; "Mark as unread" (set_unread true) sets it on a
// session's active tab.
//
// Everything from a terminal is untrusted: ids, apps, titles and messages are
// cut (PROG_*_MAX, at a character boundary) and made one line (one_line:
// no control, bidi or invisible characters); base64 is decoded, and bounded,
// by libghostty-vt before we see it.
//
// For other code (the API to rely on):
//   tab_status_view(tab)      a tab's status: dot, source, when, app, kind, message, unseen
//   session_row_status(s)     an open session's dot (the strongest of its tabs)
//   status_rank, attention_tier   ordering (the dot shown; the "attention" sort)
//   status_explain(tab)       the tooltip line: what, from which source, how long ago

import "core:fmt"
import "core:strings"
import "core:time"
import gh "../ghostty"

Prog_State :: enum u8 {
	None, // no record
	Idle,
	Working,
	Done,
	Blocked,
	Error,
}
PROG_STATE_NAMES := [Prog_State]string {
	.None    = "none",
	.Idle    = "idle",
	.Working = "working",
	.Done    = "done",
	.Blocked = "blocked",
	.Error   = "error",
}

Prog_Kind :: enum u8 {
	None,
	Permission,
	Question,
	Auth,
}
PROG_KIND_NAMES := [Prog_Kind]string{.None = "", .Permission = "permission", .Question = "question", .Auth = "auth"}

PROG_RECORDS_MAX :: 256 // per terminal (the spec: at most 256, at least 64)
PROG_ID_MAX :: 128 // bytes
PROG_APP_MAX :: 64
PROG_TITLE_MAX :: 128
PROG_MSG_MAX :: 256
PROG_PGRP_CHECK :: 500 * time.Millisecond // how often a reporting program's foreground is checked

// One OSC 7501 record (strings owned).
Prog_Record :: struct {
	id, app, title, msg: string,
	state:               Prog_State,
	kind:                Prog_Kind,
	progress:            i8, // 0-100, -1 = none
	seq:                 u64, // update order (the oldest is dropped when full)
	at:                  time.Time,
}

// A terminal's records (runtime, on the Term).
Prog_Records :: struct {
	list:    [dynamic]Prog_Record,
	seq:     u64,
	dirty:   bool, // changed since pump_all last handed the tab its summary
	pgrp:    i32, // the foreground process group at the last working or blocked report (0 = unknown)
	checked: time.Tick, // last foreground check
	fresh:   bool, // a report arrived since the last pump: check its program is still there now
	left:    bool, // the program that reported has gone (exit, prompt, left the foreground): done and error go once seen
	sent:    time.Tick, // last Program_Status sent (progress-only changes: at most one a second)
}

// A report as it arrived (strings borrowed).
Prog_Report :: struct {
	clear:               bool, // remove id and those under it ("" = all)
	state:               Prog_State,
	kind:                Prog_Kind,
	progress:            i8,
	id, app, title, msg: string,
}

// What a tab shows of its records (State, Tab.prog): the most urgent record.
// Strings owned by the tab (borrowed in a Program_Status command).
Prog_Summary :: struct {
	state:      Prog_State,
	kind:       Prog_Kind,
	progress:   i8,
	app:        string, // the record's, else its nearest ancestor's
	title, msg: string,
	id:         string,
	records:    int,
	at:         time.Time, // when that record was reported
}

// ---- records (pure: unit-tested in agent_status_test.odin) ----

@(private = "file")
prog_free_record :: proc(r: ^Prog_Record) {
	delete(r.id)
	delete(r.app)
	delete(r.title)
	delete(r.msg)
}

prog_free :: proc(r: ^Prog_Records) {
	for &x in r.list do prog_free_record(&x)
	delete(r.list)
	r^ = {}
}

// Removes every record (a new process in the tab).
prog_reset :: proc(r: ^Prog_Records) {
	if len(r.list) > 0 do r.dirty = true
	for &x in r.list do prog_free_record(&x)
	clear(&r.list)
	r.pgrp = 0
}

// Untrusted text, cut and made one line (owned).
prog_text :: proc(s: string, max: int) -> string {
	return strings.clone(cut_utf8(one_line(cut_utf8(s, max * 4), context.temp_allocator), max))
}

// "a" is "a/b"'s ancestor (or the same id); "" is everyone's.
prog_under :: proc(id, ancestor: string) -> bool {
	if ancestor == "" || id == ancestor do return true
	return len(id) > len(ancestor) && strings.has_prefix(id, ancestor) && id[len(ancestor)] == '/'
}

// Applies one report: a clear removes, anything else replaces its record.
prog_apply :: proc(r: ^Prog_Records, rep: Prog_Report, now := time.Time{}) {
	id := cut_utf8(one_line(rep.id, context.temp_allocator), PROG_ID_MAX)
	if rep.clear {
		#reverse for &x, i in r.list do if prog_under(x.id, id) {
			prog_free_record(&x)
			ordered_remove(&r.list, i)
			r.dirty = true
		}
		return
	}
	if rep.state == .None do return
	r.fresh, r.left = true, false
	r.seq += 1
	at := now != {} ? now : time.now()
	rec := Prog_Record {
		id       = strings.clone(id),
		app      = prog_text(rep.app, PROG_APP_MAX),
		title    = prog_text(rep.title, PROG_TITLE_MAX),
		msg      = prog_text(rep.msg, PROG_MSG_MAX),
		state    = rep.state,
		kind     = rep.state == .Blocked ? rep.kind : .None,
		progress = (rep.progress >= 0 && rep.progress <= 100) ? rep.progress : -1,
		seq      = r.seq,
		at       = at,
	}
	r.dirty = true
	for &x in r.list do if x.id == rec.id {
		prog_free_record(&x)
		x = rec
		return
	}
	if len(r.list) >= PROG_RECORDS_MAX { 	// full: the one updated longest ago goes
		oldest := 0
		for x, i in r.list do if x.seq < r.list[oldest].seq do oldest = i
		prog_free_record(&r.list[oldest])
		ordered_remove(&r.list, oldest)
	}
	append(&r.list, rec)
}

// The program ended (exit, a new prompt, it left the foreground): working,
// blocked and idle records go; done and error stay until seen.
prog_end_live :: proc(r: ^Prog_Records) {
	#reverse for &x, i in r.list do if x.state == .Working || x.state == .Blocked || x.state == .Idle {
		prog_free_record(&x)
		ordered_remove(&r.list, i)
		r.dirty = true
	}
	r.pgrp = 0
	r.left = true
}

// Done and error records go (their program left and the user saw them).
prog_drop_finished :: proc(r: ^Prog_Records) {
	#reverse for &x, i in r.list do if x.state == .Done || x.state == .Error {
		prog_free_record(&x)
		ordered_remove(&r.list, i)
		r.dirty = true
	}
}

prog_live :: proc(r: ^Prog_Records) -> bool {
	for x in r.list do if x.state == .Working || x.state == .Blocked do return true
	return false
}

// How urgent a record is: blocked > error > working > done > idle.
@(private = "file")
prog_urgency :: proc(s: Prog_State) -> int {
	switch s {
	case .Blocked: return 5
	case .Error:   return 4
	case .Working: return 3
	case .Done:    return 2
	case .Idle:    return 1
	case .None:    return 0
	}
	return 0
}

// The most urgent record (ties: the latest), its app inherited from the
// nearest ancestor that has one. Strings borrowed from the records.
prog_summary :: proc(r: ^Prog_Records) -> Prog_Summary {
	best := -1
	for x, i in r.list {
		if best < 0 do best = i
		else {
			b := r.list[best]
			ux, ub := prog_urgency(x.state), prog_urgency(b.state)
			if ux > ub || (ux == ub && x.seq > b.seq) do best = i
		}
	}
	if best < 0 do return {progress = -1}
	x := r.list[best]
	app := x.app
	if app == "" {
		// the nearest ancestor with an app: "a/b/c" -> "a/b" -> "a" -> ""
		up := x.id
		for app == "" && up != "" {
			cut := strings.last_index_byte(up, '/')
			up = cut < 0 ? "" : up[:cut]
			for y in r.list do if y.id == up && y.app != "" do app = y.app
		}
	}
	return {state = x.state, kind = x.kind, progress = x.progress, app = app, title = x.title, msg = x.msg, id = x.id, records = len(r.list), at = x.at}
}

// ---- the terminal side (term.odin registers these) ----

// Every terminal: OSC 7501 reports and OSC 133 prompts.
term_status_register :: proc(t: ^Term) {
	gh.terminal_set(t.gt, .Program_Status, rawptr(on_program_status))
	gh.terminal_set(t.gt, .Semantic_Prompt, rawptr(on_semantic_prompt))
}

@(private = "file")
gh_str :: proc(s: gh.String) -> string {
	if s.ptr == nil || s.len == 0 do return ""
	return string(s.ptr[:s.len])
}

on_program_status :: proc "c" (gt: gh.Terminal, userdata: rawptr, report: ^gh.Program_Status) {
	context = app_context
	t := (^Term)(userdata)
	if t == nil || report == nil do return
	rep := Prog_Report{progress = report.progress, id = gh_str(report.id), app = gh_str(report.app), title = gh_str(report.title), msg = gh_str(report.message)}
	switch report.state {
	case .Idle:    rep.state = .Idle
	case .Working: rep.state = .Working
	case .Done:    rep.state = .Done
	case .Blocked: rep.state = .Blocked
	case .Error:   rep.state = .Error
	case .Clear:   rep.clear = true
	case:          return // a state this build does not know
	}
	#partial switch report.kind {
	case .Permission: rep.kind = .Permission
	case .Question:   rep.kind = .Question
	case .Auth:       rep.kind = .Auth
	}
	prog_apply(&t.prog, rep)
	// who reported: when that program leaves the foreground, it ended
	if rep.state == .Working || rep.state == .Blocked do t.prog.pgrp = status_fg(&t.pty)
}

on_semantic_prompt :: proc "c" (gt: gh.Terminal, userdata: rawptr, event: ^gh.Semantic_Prompt) {
	context = app_context
	t := (^Term)(userdata)
	if t == nil || event == nil do return
	if event.kind == .Prompt_Start && event.prompt_kind == .Primary do prog_end_live(&t.prog)
}

// The terminal's foreground process group (tests stub it).
status_fg: proc(p: ^Pty) -> i32 = pty_foreground_pgrp
// A shell's executable (by name: /bin/sh may run as bash). Unknown ("") is not.
SHELL_NAMES :: [?]string{"sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "tcsh", "csh", "nu", "elvish", "xonsh", "ion", "pwsh"}
is_shell_exe :: proc(path: string) -> bool {
	name := path[strings.last_index_byte(path, '/') + 1:]
	name = strings.trim_prefix(name, "-") // a login shell's argv[0] style
	for n in SHELL_NAMES do if name == n do return true
	return false
}

// The executable a pty's child runs now (tests stub it).
status_exe: proc(p: ^Pty) -> string = pty_child_exe
// Program_Status commands sent (tests).
status_events: int

// pump_all, after a terminal was read: the program that reported working
// left the foreground or the process exited (its live records go), then the
// tab gets its new summary.
status_pump :: proc(tab_id: u64, t: ^Term) {
	r := &t.prog
	_, tab, _ := find_tab(tab_id)
	// done and error stay until the user saw them (the tab took them: nothing
	// pending), then go with their program
	if r.left && !r.dirty && len(r.list) > 0 && tab != nil && !tab.unseen do prog_drop_finished(r)
	if len(r.list) > 0 && !r.left {
		if !t.running {
			prog_end_live(r)
		} else if r.fresh || r.checked == {} || time.tick_since(r.checked) >= PROG_PGRP_CHECK {
			r.checked = time.tick_now()
			if status_owner_gone(t, tab) do prog_end_live(r)
		}
	}
	r.fresh = false
	if !r.dirty do return
	sum := prog_summary(r)
	if tab != nil && !prog_summary_differs(tab.prog, sum) {
		if tab.prog.progress != sum.progress && time.tick_since(r.sent) < time.Second do return // progress only: at most once a second (stays dirty)
		if tab.prog.progress == sum.progress {
			// the same status again: not news (no event); only when it was last said
			r.dirty = false
			tab.prog.at = sum.at
			return
		}
	}
	r.dirty = false
	r.sent = time.tick_now()
	status_events += 1
	run_command(Program_Status{tab_id = tab_id, summary = sum})
}

// The program that reported is gone: in a shell tab, the shell itself (or
// nobody we can tell) holds the foreground while its pid still runs a shell
// (an `exec` into an agent keeps the pid, not the shell), so a report read just after its
// program exited (`cat log`) is not left standing; in any tab, the program
// that said working or blocked left the foreground. Not a pi tab's own
// process: there the tab's pid is pi, which may report.
status_owner_gone :: proc(t: ^Term, tab: ^Tab) -> bool {
	pg := status_fg(&t.pty)
	if tab != nil {
		// the shell itself holds the foreground (forkpty made it its group's leader), as long
		// as that pid still runs the shell: `exec claude` keeps the pid and reports for real
		if _, is_shell := tab.kind.(Shell_Tab); is_shell && (pg <= 0 || pg == t.pty.pid) && is_shell_exe(status_exe(&t.pty)) do return true
	}
	return t.prog.pgrp > 0 && pg > 0 && pg != t.prog.pgrp
}

// ---- commands ----

// Internal: a tab's OSC 7501 records changed (status_pump).
Program_Status :: struct {
	tab_id:  u64,
	summary: Prog_Summary, // strings borrowed
}

// "Mark as unread" / "Mark as read": a tab (tab_id), or an open session
// (pi_session_id: unread marks its active tab, read clears all its tabs).
Set_Unread :: struct {
	tab_id:        u64,
	pi_session_id: string,
	unread:        bool,
}

status_apply :: proc(cmd: Command, caller: Caller) -> (Result, bool) {
	#partial switch c in cmd {
	case Program_Status:
		s, tab, _ := find_tab(c.tab_id)
		if tab == nil do return fail("no such tab"), false
		was := tab.prog.state
		now := c.summary.state
		changed := prog_summary_differs(tab.prog, c.summary) || tab.prog.progress != c.summary.progress
		if !s.home && !status_bridge_owns(tab^) && was != now {
			busy :: proc(x: Prog_State) -> bool {return x == .Working || x == .Blocked}
			switch {
			case busy(now):
				if tab.unseen do changed = true
				tab.unseen = false // working again: nothing left unseen
				if now == .Blocked do notify_session(s, tab, .Waiting, tab_shown = true)
			case now == .Error:
				// not seen yet: kept (red) until looked at, even after its program exits
				if !status_on_screen(s, tab.id) {
					tab.unseen = true
					changed = true
				}
				notify_session(s, tab, .Error, tab_shown = true)
			case busy(was) && now == .Idle, now == .Done: // done: a result to look at, whatever came before
				if !status_on_screen(s, tab.id) {
					tab.unseen = true
					changed = true
				}
				notify_session(s, tab, .Finished, tab_shown = true)
			}
		}
		prog_summary_set(&tab.prog, c.summary)
		return {ok = true}, changed
	case Set_Unread:
		if c.tab_id != 0 {
			s, tab, _ := find_tab(c.tab_id)
			if tab == nil do return fail("no such tab"), false
			if s.home do return fail(HOME_NOT_A_SESSION), false
			if !tab_is_terminal(tab^) do return fail("not a terminal tab"), false
			if tab.unseen == c.unread do return {ok = true}, false
			tab.unseen = c.unread
			return {ok = true}, true
		}
		if c.pi_session_id == "" do return fail("give tab_id or pi_session_id"), false
		for &s in state.open_sessions {
			if s.home || s.pi_session_id != c.pi_session_id do continue
			changed := false
			// the tab it marks: the active one if it is a terminal, else the pi tab
			mark := s.tabs[0].id
			for t in s.tabs do if t.id == s.active_tab && tab_is_terminal(t) do mark = t.id
			for &t in s.tabs {
				want := c.unread ? (t.id == mark || t.unseen) : false
				if t.unseen != want {
					t.unseen = want
					changed = true
				}
			}
			return {ok = true}, changed
		}
		return fail("the session is not open"), false
	}
	return fail("unknown command"), false
}

@(private = "file")
prog_summary_differs :: proc(a, b: Prog_Summary) -> bool {
	// not `at` (the same report again is not news) nor progress (status_pump paces it)
	return a.state != b.state || a.kind != b.kind || a.app != b.app || a.title != b.title || a.msg != b.msg || a.id != b.id || a.records != b.records
}

// Replaces a tab's summary with a copy of `from`.
prog_summary_set :: proc(to: ^Prog_Summary, from: Prog_Summary) {
	prog_summary_free(to)
	to^ = from
	to.app = strings.clone(from.app)
	to.title = strings.clone(from.title)
	to.msg = strings.clone(from.msg)
	to.id = strings.clone(from.id)
}

prog_summary_free :: proc(p: ^Prog_Summary) {
	delete(p.app)
	delete(p.title)
	delete(p.msg)
	delete(p.id)
	p^ = {progress = -1}
}

// ---- seen ----

// The user is looking at this tab now: its session is current, one of its
// panes shows it (focused or not: panes.odin), and the window is in front
// (the bell's rule).
status_on_screen :: proc(s: ^Open_Session, tab_id: u64) -> bool {
	return s != nil && !s.home && state.current_session == s.id && session_tab_shown(s, tab_id) && notify_window_active()
}

// The user looks at the session's shown tabs now (focus_session, a closed
// tab handing over): they are seen. Inside run_command.
status_seen :: proc(s: ^Open_Session) {
	if s == nil || s.home || !notify_window_active() do return
	for &t in s.tabs do if session_tab_shown(s, t.id) do t.unseen = false
}

// The tabs on screen that are unseen (main.odin: the window coming to the
// front sends set_unread false for each). Temp-allocated.
status_wants_seen :: proc() -> []u64 {
	out := make([dynamic]u64, context.temp_allocator)
	s := cur()
	if s == nil || s.home do return out[:]
	for t in s.tabs do if t.unseen && session_tab_shown(s, t.id) do append(&out, t.id)
	return out[:]
}

// A pi tab's bridge reported (Pi_Status_Update, before the tab takes it): a
// run that ended while the user was not looking is unseen; one that starts
// is not. Records when, for the tooltip.
status_bridge_report :: proc(s: ^Open_Session, tab: ^Tab, agent: Agent_State) {
	if agent == .Unknown do return
	tab.bridge_at = time.now()
	if s == nil || s.home do return
	if agent == .Working do tab.unseen = false
	else if tab.agent == .Working && agent == .Idle && !status_on_screen(s, tab.id) do tab.unseen = true
}

// ---- what a tab shows ----

Status_Source :: enum u8 {
	None,
	Bridge, // the pi bridge (pi.status)
	Osc7501, // the program's own OSC 7501 reports
}
STATUS_SOURCE_NAMES := [Status_Source]string{.None = "none", .Bridge = "bridge", .Osc7501 = "osc7501"}

Tab_Status_View :: struct {
	dot:    Row_Status,
	source: Status_Source,
	at:     time.Time, // when the source last reported ({} = never)
	state:  Prog_State, // OSC 7501's state (source osc7501)
	app:    string, // "pi" for the bridge; OSC 7501's app ("" = none); borrowed
	kind:   Prog_Kind,
	msg:    string, // OSC 7501's message (one line, untrusted); borrowed
	unseen: bool,
}

// The bridge speaks for this tab: a pi tab whose bridge reports.
status_bridge_owns :: proc(tab: Tab) -> bool {
	_, is_pi := tab.kind.(Pi_Tab)
	return is_pi && (tab.agent != .Unknown || tab.waiting)
}

// A tab's status: the bridge's while it reports, else OSC 7501's, else none
// (a pi tab: exited or not reporting yet). An unseen tab with nothing more
// urgent shows the unseen dot.
tab_status_view :: proc(tab: Tab) -> Tab_Status_View {
	v := Tab_Status_View{unseen = tab.unseen}
	_, is_pi := tab.kind.(Pi_Tab)
	switch {
	case status_bridge_owns(tab):
		v.source, v.at, v.app = .Bridge, tab.bridge_at, "pi"
		v.dot = pi_tab_status(tab)
	case tab.prog.state != .None:
		v.source, v.at, v.state = .Osc7501, tab.prog.at, tab.prog.state
		v.app, v.kind, v.msg = tab.prog.app, tab.prog.kind, tab.prog.msg
		switch tab.prog.state {
		case .Blocked:             v.dot = .Waiting
		case .Error:               v.dot = .Error
		case .Working:             v.dot = .Running
		case .Done, .Idle, .None:  v.dot = .None
		}
		if v.dot == .None && is_pi && tab.status == .Exited do v.dot = .Exited
	case is_pi:
		v.dot = pi_tab_status(tab) // exited, or none
	}
	// a Claude Code without OSC 7501: the hooks' turn (claude_status.odin; background work never
	// changes the dot)
	v.dot = claude_status_dot(tab, v.dot)
	// a Claude tab's hooks: its last turn ended on a question (Stop) or an error (StopFailure),
	// shown when OSC 7501 says nothing stronger (claude_rows.odin)
	if ct, is_claude := tab.kind.(Claude_Tab); is_claude && tab.status == .Running && v.dot == .None {
		#partial switch ct.ended {
		case .Question: v.dot = .Question
		case .Error:    v.dot = .Error
		}
	}
	// not over a dead pi tab's faint dot: its Restart bar says it exited (dead_tab.odin)
	if tab.unseen && v.dot == .None do v.dot = .Unseen
	return v
}

// A tab with a terminal: pi and shell tabs, and any other kind that runs one.
tab_is_terminal :: proc(t: Tab) -> bool {
	#partial switch _ in t.kind {
	case Pi_Tab, Shell_Tab, Claude_Tab: return true
	}
	return term_of(t.id) != nil
}

// The dot as the snapshot names it (session and tab agent_status).
ROW_STATUS_NAMES := [Row_Status]string {
	.None     = "none",
	.Running  = "working",
	.Waiting  = "waiting",
	.Question = "question",
	.Error    = "error",
	.Exited   = "exited",
	.Unseen   = "unseen",
}

// Which dot wins in a roll-up (a session's tabs, a project's sessions).
status_rank :: proc(st: Row_Status) -> int {
	switch st {
	case .None:     return 0
	case .Exited:   return 1
	case .Running:  return 2
	case .Question: return 3
	case .Unseen:   return 4
	case .Error:    return 5
	case .Waiting:  return 6
	}
	return 0
}

// The "attention" sort's tiers: needs you (blocked, error) > finished and
// not seen (or asked a question) > working > the rest.
attention_tier :: proc(st: Row_Status) -> int {
	switch st {
	case .Waiting, .Error:    return 3
	case .Unseen, .Question:  return 2
	case .Running:            return 1
	case .None, .Exited:      return 0
	}
	return 0
}

// An open session's dot: the strongest of its tabs'. Also the tab that
// gave it (nil = none).
session_row_status :: proc(s: ^Open_Session) -> (st: Row_Status, from: ^Tab) {
	if s == nil do return .None, nil
	for &t in s.tabs {
		v := tab_status_view(t)
		if from == nil || status_rank(v.dot) > status_rank(st) {
			st = v.dot
			from = &t
		}
	}
	if st == .None do from = nil
	return
}

// What the quick filters (Running, Waiting) see of a session: waiting if any
// of its tabs waits, else working if any works, else its dot. (Its dot shows
// the strongest by rank, which an unseen or errored tab may take from a
// working one.)
session_quick_status :: proc(s: ^Open_Session) -> Row_Status {
	if s == nil do return .None
	running := false
	for t in s.tabs {
		d := tab_status_view(t).dot
		if d == .Waiting do return .Waiting
		if d == .Running do running = true
	}
	if running do return .Running
	st, _ := session_row_status(s)
	return st
}

// The tooltip line for a tab's status: "claude-code: waiting for
// permission · OSC 7501, 2m ago — Apply?". "" when the tab shows no dot.
status_explain :: proc(tab: Tab) -> string {
	v := tab_status_view(tab)
	if v.dot == .None do return ""
	what: string
	switch v.dot {
	case .Waiting:  what = v.kind != .None ? fmt.tprintf("waiting for %s", PROG_KIND_NAMES[v.kind]) : "waiting for you"
	case .Running:  what = "working"
	case .Error:    what = "stopped with an error"
	case .Question: what = "asked you a question"
	case .Unseen:   what = (v.source == .Osc7501 && v.state == .Done) || v.source == .Bridge ? "finished, not seen yet" : "unread"
	case .Exited:   what = "exited"
	case .None:
	}
	_, is_claude := tab.kind.(Claude_Tab)
	who := v.app
	if who == "" do who = v.source == .Osc7501 ? "program" : (is_claude ? "claude" : "pi")
	from: string
	switch v.source {
	case .Bridge:  from = "pi bridge"
	case .Osc7501: from = "OSC 7501"
	case .None:    from = is_claude ? "Claude Code hooks" : "no status reported"
	}
	when_ := ago(v.at)
	if when_ != "" && when_ != "now" do when_ = fmt.tprintf("%s ago", when_)
	line := when_ != "" ? fmt.tprintf("%s: %s · %s, %s", who, what, from, when_) : fmt.tprintf("%s: %s · %s", who, what, from)
	if v.msg != "" do line = fmt.tprintf("%s — %s", line, cut_utf8(v.msg, 120))
	return line
}

// A session row's tooltip: its strongest tab's explanation, naming the tab
// when it is not the pi tab (a program cannot pass as another session).
session_explain :: proc(s: ^Open_Session) -> string {
	st, from := session_row_status(s)
	if from == nil || st == .None do return ""
	line := status_explain(from^)
	if _, is_pi := from.kind.(Pi_Tab); !is_pi do line = fmt.tprintf("%s: %s", cut_utf8(one_line(from.title, context.temp_allocator), 60), line)
	return line
}

// "5m", "3h", ... since t; "" for none.
ago :: proc(t: time.Time) -> string {
	if t == {} do return ""
	m := int(time.duration_minutes(time.since(t)))
	switch {
	case m < 1:             return "now"
	case m < 60:            return fmt.tprintf("%dm", m)
	case m < 24 * 60:       return fmt.tprintf("%dh", m / 60)
	case m < 7 * 24 * 60:   return fmt.tprintf("%dd", m / (24 * 60))
	case m < 365 * 24 * 60: return fmt.tprintf("%dw", m / (7 * 24 * 60))
	}
	return fmt.tprintf("%dy", m / (365 * 24 * 60))
}

pi_tab_status :: proc(tab: Tab) -> Row_Status {
	if tab.status == .Exited do return .Exited
	if tab.waiting do return .Waiting
	switch tab.agent {
	case .Error:   return .Error
	case .Working: return .Running
	case .Idle:    return tab.question ? .Question : .None
	case .Unknown: return .None
	}
	return .None
}

// A session's dot: the strongest of its open tabs (agent_status.odin).
session_status :: proc(pi_session_id: string) -> Row_Status {
	if pi_session_id == "" do return .None
	for &s in state.open_sessions {
		if s.pi_session_id != pi_session_id do continue
		st, _ := session_row_status(&s)
		return st
	}
	// a Claude session open as a tab of a pi session (its row in the left column): that tab's
	if id := claude_open_tab(pi_session_id); id != 0 do if _, tab, _ := find_tab(id); tab != nil do return tab_status_view(tab^).dot
	return .None
}
