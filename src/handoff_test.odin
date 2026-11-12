package main

// "New session on <machine>…" (ui_handoff.odin, core/handoff.odin): a local project's matches on
// the machines online now, by exact folder name; the rows in the project's, session's and open
// row's menus; choosing one does what that project's "+ New session" does, with only its packed
// id; a hostile remote name is drawn cleaned and can't match through its control characters.

import "base:runtime"
import "core:strings"
import "core:testing"
import "core"

@(private = "file")
Fixture :: struct {
	r3, r4, r5: core.State,
	m3, m4, m5: core.Machine_Mirror,
}

@(private = "file")
NUC_CHECKS := [2]core.Machine_Check{{id = "pi", state = .Ok}, {id = "claude", state = .Ok}}

@(private = "file")
remote_project :: proc(r: ^core.State, id: u64, cwd: string) {
	append(&r.projects, core.Project{id = id, group = .Projects, cwd = strings.clone(cwd), label = strings.clone(cwd)})
}

// This Mac's project 1 (".../code/api"), its Chats; nuc (3, online) with api once and one
// unrelated; box (4, online) with api twice, an "API" and a hostile "a\x1bpi"; old (5, offline)
// with api.
@(private = "file")
setup :: proc(f: ^Fixture) {
	state^ = core.State{}
	state.settings.remote_machines = true
	state.layout.left_open, state.layout.left_width, state.layout.left_tab = true, 400, .Sessions
	append(&state.projects, core.Project{id = 1, group = .Projects, cwd = strings.clone("/Users/me/code/api"), label = strings.clone("code/api")})
	append(&state.projects, core.Project{id = 2, group = .Chats, cwd = strings.clone("/Users/me/chats/api"), label = strings.clone("api")})
	state.selected_project = 1
	state.machines = make([]core.Machine_View, 3)
	state.machines[0] = {no = 3, name = "nuc", target = "jb@nuc", status = .Online, core_run = "r-nuc-1", checklist = NUC_CHECKS[:]}
	state.machines[1] = {no = 4, name = "box", target = "jb@box", status = .Online, core_run = "r-box-1"}
	state.machines[2] = {no = 5, name = "old", target = "old", status = .Offline}
	remote_project(&f.r3, 7, "/home/jb/src/api")
	remote_project(&f.r3, 8, "/home/jb/src/web")
	remote_project(&f.r4, 7, "/home/jb/work/api")
	remote_project(&f.r4, 8, "/srv/api")
	remote_project(&f.r4, 9, "/home/jb/API")
	remote_project(&f.r4, 10, "/home/jb/a\x1bpi‮")
	remote_project(&f.r5, 7, "/home/jb/api")
	core.mirror_merge(3, &f.r3, &f.m3)
	core.mirror_merge(4, &f.r4, &f.m4)
	core.mirror_merge(5, &f.r5, &f.m5)
}

@(private = "file")
teardown :: proc(f: ^Fixture) {
	core.inbox_drain()
	if menu.open do menu_close()
	for no in ([]u64{3, 4, 5}) do core.mirror_unmerge(no)
	core.mirror_free(&f.m3)
	core.mirror_free(&f.m4)
	core.mirror_free(&f.m5)
	core.replica_free(&f.r3, runtime.heap_allocator())
	core.replica_free(&f.r4, runtime.heap_allocator())
	core.replica_free(&f.r5, runtime.heap_allocator())
	toast_clear()
	state^ = core.State{}
}

// The window draws the menu (what a click acts on is what was drawn last).
@(private = "file")
drawn_now :: proc() {
	audit_ui()
	_ = ui_layout(2000, 1400)
}

@(private = "file")
pid :: proc(no, id: u64) -> u64 {
	p, _ := core.id_pack(no, id)
	return p
}

@(private = "file")
labels :: proc(items: []core.Menu_Item) -> string {
	b := strings.builder_make(context.temp_allocator)
	for it, i in items {
		if i > 0 do strings.write_byte(&b, '|')
		strings.write_string(&b, it.sep ? "-" : it.label)
	}
	return strings.to_string(b)
}

@(private = "file")
handoff_rows :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for it in menu_items() do if strings.has_prefix(it.label, "New session on ") {
		if strings.builder_len(b) > 0 do strings.write_byte(&b, '|')
		strings.write_string(&b, it.label)
	}
	return strings.to_string(b)
}

@(test)
handoff_matching :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Fixture
	setup(&f)
	defer teardown(&f)

	// exact folder name, online machines only (old's api is not offered), in the machines' order;
	// box has two: each with its folder there; "API" and the hostile one don't match
	got := core.handoff_targets(1)
	testing.expect_value(t, len(got), 3)
	if len(got) == 3 {
		testing.expect_value(t, got[0].label, "New session on nuc in api")
		testing.expect_value(t, got[0].project_id, pid(3, 7))
		testing.expect_value(t, got[1].label, "New session on box in api (~/work/api)")
		testing.expect_value(t, got[1].project_id, pid(4, 7))
		testing.expect_value(t, got[2].label, "New session on box in api (/srv/api)")
		testing.expect_value(t, got[2].project_id, pid(4, 8))
	}
	// Chats, another machine's project, and an unknown id: nothing
	testing.expect_value(t, len(core.handoff_targets(2)), 0)
	testing.expect_value(t, len(core.handoff_targets(pid(3, 7))), 0)
	testing.expect_value(t, len(core.handoff_targets(99)), 0)
	// no project of that name anywhere online: no rows
	state.projects[0].cwd = strings.clone("/Users/me/code/garden")
	testing.expect_value(t, len(core.handoff_targets(1)), 0)
	state.projects[0].cwd = strings.clone("/Users/me/code/api")
	// both online machines offline: none
	state.machines[0].status, state.machines[1].status = .Offline, .Connecting
	testing.expect_value(t, len(core.handoff_targets(1)), 0)
	state.machines[0].status, state.machines[1].status = .Online, .Online
	// Machines over SSH off: none
	state.settings.remote_machines = false
	testing.expect_value(t, len(core.handoff_targets(1)), 0)
	state.settings.remote_machines = true

	// the hostile name: mirrored cleaned (no control or bidi character left), and it does not
	// become "api"; the folder shortened
	hostile := core.find_project(pid(4, 10))
	if testing.expect(t, hostile != nil, "mirrored") {
		for r in hostile.cwd do testing.expectf(t, r >= 0x20 && r != 0x7f && r != 0x202e, "cleaned: %q", hostile.cwd)
		testing.expect(t, core.handoff_name(hostile.cwd) != "api", hostile.cwd)
	}
	testing.expect_value(t, core.handoff_short("/home/jb", "jb"), "~")
	testing.expect_value(t, core.handoff_short("/Users/jb/x/y", "jb"), "~/x/y")
	testing.expect_value(t, core.handoff_short("/root/api", "root"), "~/api")
	testing.expect_value(t, core.handoff_short("/opt/api", "jb"), "/opt/api")
	// only the home of the user its link logs in as; not known: in full
	testing.expect_value(t, core.handoff_short("/home/alice/api", "jb"), "/home/alice/api")
	testing.expect_value(t, core.handoff_short("/home/jbx/api", "jb"), "/home/jbx/api")
	testing.expect_value(t, core.handoff_short("/home/jb/api", ""), "/home/jb/api")
	testing.expect_value(t, core.handoff_short("/root/api", "jb"), "/root/api")
	testing.expect_value(t, core.handoff_name("/"), "")
	testing.expect_value(t, core.handoff_name(""), "")
}

@(test)
handoff_menus :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Fixture
	setup(&f)
	defer teardown(&f)
	want := "New session on nuc in api|New session on box in api (~/work/api)|New session on box in api (/srv/api)"

	// the project's menu: right after its New session
	menu_open(Menu_Project(1), {})
	all := labels(menu_items())
	testing.expectf(t, strings.contains(all, strings.concatenate({"New session|", want}, context.temp_allocator)), "project menu: %q", all)
	// each row is that project's harness picker, with no folder of this Mac's
	for it in menu_items() do if strings.has_prefix(it.label, "New session on ") {
		ns, ok := it.picker.?
		testing.expect(t, ok && core.id_machine(ns.project_id) != 0 && ns.cwd == "" && it.cmd == nil, it.label)
	}
	// drawn as such (a hostile name never reaches a row: it does not match)
	if testing.expect(t, audit_ui(), "fonts") {
		cmds := ui_layout(2000, 1400)
		drawn := strings.builder_make(context.temp_allocator)
		for i in 0 ..< cmds.length {
			c := &cmds.internalArray[i]
			if c.commandType != .Text do continue
			tx := c.renderData.text
			strings.write_string(&drawn, string(tx.stringContents.chars[:tx.stringContents.length]))
			strings.write_byte(&drawn, '\n')
		}
		d := strings.to_string(drawn)
		testing.expectf(t, strings.contains(d, "New session on nuc in api\n") && strings.contains(d, "New session on box in api (~/work/api)\n"), "drawn: %q", d)
		testing.expect(t, !strings.contains(d, "\x1b") && !strings.contains(d, "‮"), "nothing hostile drawn")
	}
	menu_close()

	// a session row's and an open row's menu (both Menu_Session of this Mac's project)
	menu_open(Menu_Session{project_id = 1, pi_session_id = "s1"}, {})
	testing.expect_value(t, handoff_rows(), want)
	menu_close()
	// Chats' session menu, and the info menu: none
	menu_open(Menu_Session{project_id = 2, pi_session_id = "s2"}, {})
	testing.expect_value(t, handoff_rows(), "")
	menu_close()
	menu_open(Menu_Session{project_id = 1, pi_session_id = "s1", info = "x"}, {})
	testing.expect_value(t, handoff_rows(), "")
	menu_close()
	// no match: no row, nothing disabled
	state.machines[0].status, state.machines[1].status = .Offline, .Offline
	menu_open(Menu_Project(1), {})
	testing.expect_value(t, handoff_rows(), "")
	menu_close()
}

// Choosing a row does what "+ New session" under that project does: select it, then its picker
// (main.odin's Hit_New: new_session_ui(state.selected_project)), the same commands.
@(test)
handoff_runs_new_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Fixture
	setup(&f)
	defer teardown(&f)

	menu_open(Menu_Project(1), {})
	at := -1
	for it, i in menu_items() do if it.label == "New session on nuc in api" do at = i
	if !testing.expect(t, at >= 0, "the row") do return
	drawn_now()
	menu_run(at)
	core.inbox_drain()
	testing.expect_value(t, state.selected_project, pid(3, 7))
	ns, is_ns := menu.target.(core.Menu_New_Session)
	testing.expect(t, menu.open && is_ns && ns.project_id == pid(3, 7) && ns.cwd == "", "nuc's api's picker")
	ours := make([dynamic]core.Command, context.temp_allocator)
	for it in menu_items() do if it.cmd != nil do append(&ours, it.cmd)
	menu_close()

	// "+ New session" under that project, selected
	new_session_ui(state.selected_project)
	theirs := make([dynamic]core.Command, context.temp_allocator)
	for it in menu_items() do if it.cmd != nil do append(&theirs, it.cmd)
	menu_close()
	testing.expect_value(t, len(ours), 2)
	testing.expect_value(t, len(ours), len(theirs))
	for c, i in ours {
		if i >= len(theirs) do break
		#partial switch x in c {
		case core.New_Chat:
			y, ok := theirs[i].(core.New_Chat)
			testing.expect(t, ok && x == y && x.project_id == pid(3, 7), "pi there")
		case core.New_Claude_Session:
			y, ok := theirs[i].(core.New_Claude_Session)
			// that machine's own account: no folder, account or session of this Mac's
			testing.expect(t, ok && x.project_id == y.project_id && x.project_id == pid(3, 7) && x.cwd == "" && x.account == "" && y.cwd == "" && y.account == "", "Claude Code there")
		case:
			testing.expectf(t, false, "unexpected %v", c)
		}
	}
}

// The palette's "New session on another machine…": the selected project's; none: a toast; one:
// at once; several: their menu.
@(test)
handoff_palette_action :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Fixture
	setup(&f)
	defer teardown(&f)

	testing.expect(t, action_ok("new_session_elsewhere"), "listed for this Mac's project")
	// several: their menu
	action_run("new_session_elsewhere")
	_, is_menu := menu.target.(Menu_Handoff)
	testing.expect(t, menu.open && is_menu, "the matches' menu")
	testing.expect_value(t, labels(menu_items()), "New session on nuc in api|New session on box in api (~/work/api)|New session on box in api (/srv/api)")
	menu_close()
	// one (box offline): straight to nuc's picker
	state.machines[1].status = .Offline
	action_run("new_session_elsewhere")
	core.inbox_drain()
	ns, is_ns := menu.target.(core.Menu_New_Session)
	testing.expect(t, menu.open && is_ns && ns.project_id == pid(3, 7), "nuc's picker")
	testing.expect_value(t, state.selected_project, pid(3, 7))
	menu_close()
	// none: a toast naming the folder
	state.selected_project = 1
	state.machines[0].status = .Offline
	action_run("new_session_elsewhere")
	testing.expect_value(t, toast.text, "No online machine has a project called api")
	testing.expect(t, !menu.open, "no menu")
	// another machine's project or Chats selected: not listed
	state.selected_project = 2
	testing.expect(t, !action_ok("new_session_elsewhere"), "not for Chats")
	state.selected_project = pid(3, 7)
	testing.expect(t, !action_ok("new_session_elsewhere"), "not for another machine's project")
}

// A row acts on what it showed: the list changed after it was drawn (nuc went offline, so the
// row under the pointer is box's now): nothing starts, a toast says so. Drawn again, box's row is
// box's. A project gone or moved since: the same.
@(test)
handoff_click_is_what_was_drawn :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Fixture
	setup(&f)
	defer teardown(&f)

	row :: proc(label: string) -> int {
		for it, i in menu_items() do if it.label == label do return i
		return -1
	}
	menu_open(Menu_Project(1), {})
	drawn_now()
	at := row("New session on nuc in api")
	if !testing.expect(t, at >= 0, "nuc's row") do return
	state.machines[0].status = .Offline // before the click, after the draw
	testing.expect_value(t, menu_items()[at].label, "New session on box in api (~/work/api)")
	menu_run(at)
	core.inbox_drain()
	testing.expect_value(t, toast.text, "That machine is no longer available")
	testing.expect_value(t, state.selected_project, 1)
	_, picker := menu.target.(core.Menu_New_Session)
	testing.expect(t, !picker, "no picker")
	if menu.open do menu_close()
	toast_clear()

	// drawn again: the row there is box's, and it is box's that starts
	menu_open(Menu_Project(1), {})
	drawn_now()
	menu_run(row("New session on box in api (~/work/api)"))
	core.inbox_drain()
	testing.expect_value(t, state.selected_project, pid(4, 7))
	testing.expect(t, toast.text != HANDOFF_GONE, toast.text) // box has pi only: it starts at once
	if menu.open do menu_close()
	state.selected_project = 1
	state.machines[0].status = .Online

	// its folder changed since the draw (another project under that id): nothing starts
	menu_open(Menu_Project(1), {})
	drawn_now()
	at = row("New session on nuc in api")
	if p := core.find_project(pid(3, 7)); p != nil do p.cwd = "/home/jb/other/api"
	menu_run(at)
	core.inbox_drain()
	testing.expect_value(t, toast.text, "That machine is no longer available")
	testing.expect_value(t, state.selected_project, 1)
	if menu.open do menu_close()
	toast_clear()
	if p := core.find_project(pid(3, 7)); p != nil do p.cwd = "/home/jb/src/api"

	// that machine's core restarted since the draw: the same
	menu_open(Menu_Project(1), {})
	drawn_now()
	at = row("New session on nuc in api")
	state.machines[0].core_run = "r-nuc-2"
	menu_run(at)
	core.inbox_drain()
	testing.expect_value(t, toast.text, "That machine is no longer available")
	testing.expect_value(t, state.selected_project, 1)
}

// One machine with many matches can't flood the menu: at most 3 rows per machine and 8 in all,
// then "and N more on <machine>" as plain text.
@(test)
handoff_capped :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Fixture
	setup(&f)
	defer teardown(&f)
	core.mirror_unmerge(4)
	for i in 0 ..< 200 do remote_project(&f.r4, u64(100 + i), strings.concatenate({"/srv/", strings.repeat("x", i % 7 + 1, context.temp_allocator), "/", strings.repeat("y", i / 7 + 1, context.temp_allocator), "/api"}, context.temp_allocator))
	core.mirror_merge(4, &f.r4, &f.m4)

	got := core.handoff_targets(1)
	rows, notes := 0, 0
	for g in got {
		if g.project_id == 0 do notes += 1
		else do rows += 1
	}
	testing.expect_value(t, rows, 4) // nuc 1, box 3
	testing.expect_value(t, notes, 1)
	testing.expect_value(t, got[len(got) - 1].label, "and 199 more on box")
	menu_open(Menu_Project(1), {})
	items := menu_items()
	testing.expect(t, len(items) < 30, "bounded")
	for it in items do if it.label == "and 199 more on box" do testing.expect(t, it.note, "plain text")
	menu_close()

	// 8 in all: more machines with matches each add their note
	machines := make([]core.Machine_View, 5)
	copy(machines, state.machines)
	machines[3] = {no = 6, name = "m6", status = .Online}
	machines[4] = {no = 7, name = "m7", status = .Online}
	state.machines = machines
	r6, r7: core.State
	m6, m7: core.Machine_Mirror
	for i in 0 ..< 5 {
		remote_project(&r6, u64(10 + i), strings.concatenate({"/a", strings.repeat("z", i + 1, context.temp_allocator), "/api"}, context.temp_allocator))
		remote_project(&r7, u64(10 + i), strings.concatenate({"/b", strings.repeat("z", i + 1, context.temp_allocator), "/api"}, context.temp_allocator))
	}
	core.mirror_merge(6, &r6, &m6)
	core.mirror_merge(7, &r7, &m7)
	defer {
		core.mirror_unmerge(6)
		core.mirror_unmerge(7)
		core.mirror_free(&m6)
		core.mirror_free(&m7)
		core.replica_free(&r6, runtime.heap_allocator())
		core.replica_free(&r7, runtime.heap_allocator())
	}
	got = core.handoff_targets(1)
	rows = 0
	b := strings.builder_make(context.temp_allocator)
	for g in got {
		if g.project_id != 0 do rows += 1
		else do strings.write_string(&b, g.label)
	}
	testing.expect_value(t, rows, 8) // nuc 1, box 3, m6 3, m7 1
	testing.expect_value(t, strings.to_string(b), "and 199 more on boxand 2 more on m6and 4 more on m7")
}

// Several on a machine stay told apart: another user's home in full, a long folder cut in its
// middle (both ends kept).
@(test)
handoff_folders_distinct :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Fixture
	setup(&f)
	defer teardown(&f)
	core.mirror_unmerge(4)
	clear(&f.r4.projects)
	long := strings.concatenate({"/srv/", strings.repeat("deep/", 30, context.temp_allocator), "end/api"}, context.temp_allocator)
	remote_project(&f.r4, 20, "/home/jb/work/api")
	remote_project(&f.r4, 21, "/home/alice/work/api")
	remote_project(&f.r4, 22, long)
	core.mirror_merge(4, &f.r4, &f.m4)

	got := core.handoff_targets(1)
	testing.expect_value(t, len(got), 4)
	if len(got) != 4 do return
	testing.expect_value(t, got[1].label, "New session on box in api (~/work/api)")
	testing.expect_value(t, got[2].label, "New session on box in api (/home/alice/work/api)")
	l := got[3].label
	testing.expectf(t, strings.has_prefix(l, "New session on box in api (/srv/deep/") && strings.has_suffix(l, "/end/api)") && strings.contains(l, "…") && len(l) < 100, "middle-clipped: %q", l)
	// the link's user not known (an ssh config name): every folder in full
	state.machines[1].target = "box"
	got = core.handoff_targets(1)
	testing.expect_value(t, got[1].label, "New session on box in api (/home/jb/work/api)")
}

// An open harness picker for another machine's project starts nothing once that machine's core
// restarted (its run id changed) or the project under that id has another folder: a toast says
// to choose the project again. The existing "+ New session" too (Hit_New: new_session_ui).
@(test)
handoff_picker_restart :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	f: Fixture
	setup(&f)
	defer teardown(&f)
	pick :: proc() -> int {
		for it, i in menu_items() do if it.label == "pi" do return i
		return -1
	}

	state.selected_project = pid(3, 7)
	new_session_ui(pid(3, 7)) // "+ New session" under nuc's api
	testing.expect(t, menu.open, "the picker")
	state.machines[0].core_run = "r-nuc-2"
	menu_run(pick())
	core.inbox_drain()
	testing.expect(t, !menu.open, "closed")
	testing.expect_value(t, toast.text, "That machine restarted: choose the project again")
	toast_clear()

	new_session_ui(pid(3, 7))
	if p := core.find_project(pid(3, 7)); p != nil do p.cwd = "/home/jb/elsewhere/api"
	menu_run(pick())
	core.inbox_drain()
	testing.expect(t, !menu.open, "closed")
	testing.expect_value(t, toast.text, "That machine restarted: choose the project again")
	toast_clear()
	if p := core.find_project(pid(3, 7)); p != nil do p.cwd = "/home/jb/src/api"

	// unchanged: it goes (the route says the machine's link is down here: not that toast)
	new_session_ui(pid(3, 7))
	menu_run(pick())
	core.inbox_drain()
	testing.expect(t, toast.text != "That machine restarted: choose the project again", toast.text)
}
