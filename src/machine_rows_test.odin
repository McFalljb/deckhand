package main

// Another machine in the sidebar, as drawn (ui_sidebar.odin's machines_sections; core/sidebar.odin's
// machine_open_rows and machine_project_rows): its header (status, or a note of at most two lines
// that says what is wrong, its button, its "…", its count and fold), its rows drawn as this Mac's
// (waiting, time), through the filter and quick filters; this Mac's header folds too; the palette
// names the machine; the Jobs tab says its status as the sidebar does. And none of it overlaps at
// the narrowest sidebar.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"

@(private = "file")
drawn_text :: proc(w: f32 = 2000) -> string {
	cmds := ui_layout(w, 1400)
	all := strings.builder_make(context.temp_allocator)
	for i in 0 ..< cmds.length {
		c := &cmds.internalArray[i]
		if c.commandType != .Text do continue
		tx := c.renderData.text
		strings.write_string(&all, string(tx.stringContents.chars[:tx.stringContents.length]))
		strings.write_byte(&all, '\n')
	}
	return strings.to_string(all)
}

@(test)
machine_rows_remote :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	state^ = core.State{}
	state.settings.remote_machines = true
	state.layout.left_open, state.layout.left_width, state.layout.left_tab = true, 400, .Sessions
	state.machines = make([]core.Machine_View, 2)
	state.machines[0] = {no = 3, name = "nuc", target = "me@nuc", status = .Online}
	state.machines[1] = {no = 4, name = "box", target = "box", status = .Online}
	r: core.State
	append(&r.projects, core.Project{id = 5, group = .Projects, cwd = strings.clone("/home/me/garden"), label = strings.clone("garden")})
	s := core.Open_Session{id = 9, project_id = 5, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me/garden"), title = strings.clone("Plant the beans")}
	append(&s.tabs, core.Tab{id = 10, kind = core.Pi_Tab{}, title = strings.clone("pi"), status = .Running, waiting = true})
	s.active_tab = 10
	append(&r.open_sessions, s)
	r.selected_project = 5
	append(&r.sessions, core.Session{id = strings.clone("def"), path = strings.clone("/home/me/.pi/def.jsonl"), title = strings.clone("Water the tomatoes"), when_ = strings.clone("2026-11-10 10:00"), modified = time.time_add(time.now(), -2 * time.Hour)})
	m: core.Machine_Mirror
	core.mirror_merge(3, &r, &m)
	defer {
		core.mirror_unmerge(3)
		core.mirror_free(&m)
		core.replica_free(&r, runtime.heap_allocator())
		clear(&state.machine_jobs)
		state^ = core.State{}
	}
	sid, _ := core.id_pack(3, 9)
	pid, _ := core.id_pack(3, 5)
	tab_id, _ := core.id_pack(3, 10)
	_, tab, _ := core.find_tab(tab_id)
	if !testing.expect(t, tab != nil, "its tab merged") do return

	// online, a session waiting: its header (name, status, its open count), no standing button
	// (Open web page… is in its "…"); its open row as this Mac's: place, title, Waiting for you
	got := drawn_text()
	testing.expectf(t, strings.contains(got, "nuc\nOnline\n1\n"), "the header: %q", got)
	testing.expect(t, !strings.contains(got, "Open web page…"), "no standing Open web page…")
	testing.expect(t, clay_found("machmore", 3) && clay_found("machmore", 0), "every machine's header has its …, this Mac's too")
	// their menus: Settings' Machines group from both; this Mac's adds a machine
	menu_open(Menu_Machine(0), {})
	testing.expect_value(t, menu_labels(), "Add a machine…|Machines settings…")
	menu_open(Menu_Machine(3), {})
	testing.expect_value(t, menu_labels(), "Open web page…|-|Rename…|Remove…|-|Machines settings…")
	// its open session's menu: no Mark as unread or read (it would change only this Mac's copy,
	// which that machine's next update overwrites); Close session goes there
	if rs := core.find_session(sid); testing.expect(t, rs != nil, "its session merged") {
		menu_open(Menu_Session{project_id = pid, pi_session_id = rs.pi_session_id}, {})
		labels := menu_labels()
		testing.expectf(t, strings.contains(labels, "Close session") && !strings.contains(labels, "Mark as"), "its session's menu: %q", labels)
	}
	menu_close()
	testing.expectf(t, strings.contains(got, "garden ·\nPlant the beans\nWaiting for you\n"), "its open row: %q", got)
	testing.expectf(t, strings.contains(got, "\ngarden\n1\n"), "its project row with its open count: %q", got)

	// the selected project's sessions, with their time
	state.selected_project = pid
	core.mirror_sessions_show(3, &m)
	got = drawn_text()
	testing.expectf(t, strings.contains(got, "Water the tomatoes\n2h\n"), "its session row's time: %q", got)

	// the filter and the chips thin its rows; its header stays (waiting work always shows)
	tab.waiting = false
	state.sidebar.filter = "zzz"
	got = drawn_text()
	testing.expectf(t, strings.contains(got, "nuc\n") && !strings.contains(got, "Plant the beans") && strings.contains(got, "No matches"), "filtered out: %q", got)
	state.sidebar.filter = "beans"
	testing.expect(t, strings.contains(drawn_text(), "Plant the beans"), "a match shows")
	state.sidebar.filter = ""
	state.sidebar.only_waiting = true
	testing.expect(t, !strings.contains(drawn_text(), "Plant the beans"), "Waiting: not waiting, not shown")
	tab.waiting = true
	testing.expect(t, strings.contains(drawn_text(), "Plant the beans"), "Waiting: waiting, shown")
	state.sidebar.only_waiting = false

	// folded: only its waiting open rows
	state.selected_project = 0
	machine_fold_toggle(3)
	got = drawn_text()
	testing.expectf(t, strings.contains(got, "Waiting for you") && !strings.contains(got, "\ngarden\n"), "folded: %q", got)
	tab.waiting = false
	testing.expect(t, !strings.contains(drawn_text(), "Plant the beans"), "folded: nothing that waits, nothing")
	// a question needs the user as a block does (tab_need): its row stays as well (drawn as often
	// as the waiting one was: the row and the empty centre's list)
	tab.agent, tab.question = .Idle, true
	testing.expect_value(t, strings.count(drawn_text(), "Plant the beans"), strings.count(got, "Plant the beans"))
	tab.agent, tab.question = .Unknown, false
	testing.expect(t, !strings.contains(drawn_text(), "Plant the beans"), "folded: the question answered, gone")
	machine_fold_toggle(3)
	testing.expect(t, !machine_folded(3), "unfolded")

	// this Mac's header folds: its sections go
	testing.expect(t, strings.contains(drawn_text(), "PROJECTS"), "this Mac's sections")
	state.sidebar.folded[.This_Mac] = true
	got = drawn_text()
	testing.expectf(t, !strings.contains(got, "PROJECTS") && strings.contains(got, "this Mac") && strings.contains(got, "garden"), "this Mac folded: %q", got)
	state.sidebar.folded[.This_Mac] = false

	// an online machine with nothing: what makes a project appear there
	testing.expect(t, strings.contains(drawn_text(), "No projects there yet"), "the empty machine's hint")

	// a note under the header says what is wrong: no status beside the name, no pointer at the button
	state.machines[0].status = .Needs_Login
	state.machines[0].error = "me@nuc: Permission denied (publickey)."
	got = drawn_text()
	testing.expectf(t, strings.contains(got, "nuc\n1\nLog in…\n") && strings.contains(got, "ssh wants a password or a key\n") && !strings.contains(got, "Needs you to log in"), "needs login: %q", got)
	// an update to make on that machine: no button, the note (two lines, not cut) says what to do
	state.machines[0].status, state.machines[0].update = .Needs_Update, .Command_Only
	got = drawn_text()
	flat, _ := strings.replace_all(got, "\n", " ", context.temp_allocator)
	testing.expectf(t, !strings.contains(got, "\nUpdate\n") && strings.contains(flat, "Its Deckhand wasn't installed by Deckhand: update it on that machine"), "command only: %q", got)
	state.machines[0].update = .None

	// offline: one word, here and in the Jobs tab
	state.machines[0].status, state.machines[0].error = .Offline, ""
	testing.expect(t, strings.contains(drawn_text(), "nuc\nOffline\n"), "offline header")
	append(&state.machine_jobs, core.Job_Row{id = "m3:nightly", machine = 3, name = "Nightly", owner = .Other, owner_name = "Other"})
	append(&state.machine_jobs, core.Job_Row{id = "m3:beds", machine = 3, name = "Weed the beds", owner = .Project, owner_name = "garden"})
	state.settings.home_dir = "/tmp/pd-mrows-notes"
	state.layout.left_tab = .Jobs
	got = drawn_text()
	testing.expectf(t, strings.contains(got, "On nuc\nOffline\n"), "the Jobs tab: %q", got)
	// under their owner there, as this Mac's: On nuc › garden › Weed the beds, then Other
	at_g, at_o := strings.index(got, "garden\n1\nWeed the beds\n"), strings.index(got, "Other\n1\nNightly\n")
	testing.expectf(t, at_g >= 0 && at_o > at_g, "grouped by owner: %q", got)
	// an older core sends no owner: a flat list under its name, as before
	state.machine_jobs[0].owner_name, state.machine_jobs[1].owner_name = "", ""
	got = drawn_text()
	testing.expectf(t, strings.contains(got, "On nuc\nOffline\nNightly\n") && !strings.contains(got, "\ngarden\n"), "flat: %q", got)
	state.layout.left_tab = .Sessions

	// the palette names the machine its items are on
	found := false
	for it in palette_items() do if it.id == sid && it.kind == .Session do found = strings.has_suffix(it.detail, "on nuc")
	testing.expect(t, found, "the palette's item for its open session says on nuc")

	// its session on screen while it is not online: a bar says so, with its header's button
	state.current_session = sid
	got = drawn_text()
	testing.expectf(t, strings.contains(got, "nuc is offline: showing what it last sent\nConnect\n"), "offline bar: %q", got)
	_ = ui_layout(2000, 1400)
	testing.expect(t, clay.GetElementData(clay.ID("machine_bar_act")).found, "its button")
	state.machines[0].status = .Connecting
	testing.expect(t, strings.contains(drawn_text(), "nuc: Connecting… — showing what it last sent"), "connecting bar")
	state.machines[0].status = .Online
	testing.expect(t, !strings.contains(drawn_text(), "showing what it last sent"), "online: no bar")
	state.machines[0].status = .Offline

	// no overlap at the narrowest sidebar, in each state, hovered (its session on screen: the bar too)
	state.layout.left_width = core.LEFT_MIN
	for st in ([]core.Machine_Status{.Online, .Needs_Login, .Not_Installed, .Taken, .Offline}) {
		state.machines[0].status = st
		for h in ([]Hit{nil, Hit_Machine_Head(3), Hit_Machine_More(3), Hit_Machine_More(0), Hit_Machine(3), Hit_Open_Row(sid), Hit_Project(pid)}) {
			ui_hover = h
			for bad in audit(ui_layout(800, 1400), fmt.tprintf("%v hover %v", st, h), 800) do testing.expect(t, false, bad)
		}
	}
	ui_hover = nil
	state.current_session = 0
}

@(private = "file")
menu_labels :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for it, i in menu_items() {
		if i > 0 do strings.write_byte(&b, '|')
		strings.write_string(&b, it.sep ? "-" : it.label)
	}
	return strings.to_string(b)
}

@(private = "file")
clay_found :: proc(name: string, i: u32) -> bool {
	_ = ui_layout(2000, 1400)
	return clay.GetElementData(clay.ID(name, i)).found
}

// Review round 1: a remote Claude row never shows this Mac's account label; Enter in the filter
// selects a remote project the filter left; renaming while this Mac is folded still shows the field.
@(test)
machine_rows_review :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	state^ = core.State{}
	state.settings.remote_machines = true
	state.layout.left_open, state.layout.left_width, state.layout.left_tab = true, 400, .Sessions
	state.machines = make([]core.Machine_View, 1)
	state.machines[0] = {no = 3, name = "nuc", target = "me@nuc", status = .Online}
	r: core.State
	append(&r.projects, core.Project{id = 5, group = .Projects, cwd = strings.clone("/home/me/garden"), label = strings.clone("garden")})
	append(&r.projects, core.Project{id = 6, group = .Projects, cwd = strings.clone("/home/me/orchard"), label = strings.clone("orchard")})
	s := core.Open_Session{id = 9, project_id = 5, agent = .Claude, pi_session_id = strings.clone("abc"), cwd = strings.clone("/home/me/garden"), title = strings.clone("Prune the roses")}
	append(&s.tabs, core.Tab{id = 10, kind = core.Claude_Tab{}, title = strings.clone("claude"), status = .Running})
	s.active_tab = 10
	append(&r.open_sessions, s)
	r.selected_project = 5
	append(&r.sessions, core.Session{id = strings.clone("def"), path = strings.clone("/home/me/.claude/def.jsonl"), title = strings.clone("Water the tomatoes"), when_ = strings.clone("2026-11-10 10:00"), modified = time.time_add(time.now(), -2 * time.Hour), claude = true})
	m: core.Machine_Mirror
	core.mirror_merge(3, &r, &m)
	acct := fmt.tprintf("%s/pd-mrows-acct-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	os.make_directory_all(acct)
	append(&state.settings.claude_accounts, core.Claude_Account_Setting{dir = strings.clone(acct), label = strings.clone("Work"), added = true})
	defer {
		core.mirror_unmerge(3)
		core.mirror_free(&m)
		core.replica_free(&r, runtime.heap_allocator())
		state^ = core.State{}
		os.remove(acct)
	}
	pid, _ := core.id_pack(3, 5)
	orchard, _ := core.id_pack(3, 6)

	// several accounts here: a remote Claude row (open, or its project's) has no tag (its account is
	// that machine's, unknown here), never this Mac's default's
	testing.expect(t, core.claude_accounts_many(), "two accounts here")
	state.selected_project = pid
	core.mirror_sessions_show(3, &m)
	got := drawn_text()
	testing.expectf(t, strings.contains(got, "Prune the roses") && strings.contains(got, "Water the tomatoes") && !strings.contains(got, "\nClaude\n"), "no account tag: %q", got)

	// Enter in the filter: the remote project it left is selected, as a click would
	state.selected_project = 0
	state.sidebar.filter = "orch"
	cmd, ok := core.sidebar_best_match().(core.Select_Project)
	testing.expectf(t, ok && cmd.project_id == orchard, "best match: %v", core.sidebar_best_match())
	state.sidebar.filter = ""

	// renaming while this Mac's header is folded: its field shows (on top, as under a folded Projects)
	state.sidebar.folded[.This_Mac] = true
	for w in ([]string{"rename_project", "rename_session"}) {
		state.focus_widget = w
		_ = ui_layout(2000, 1400)
		testing.expectf(t, clay.GetElementData(clay.ID("rename_field")).found, "%s: the field shows", w)
	}
	state.focus_widget = ""
}
