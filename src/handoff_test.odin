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
	state.machines[0] = {no = 3, name = "nuc", target = "jb@nuc", status = .Online, checklist = NUC_CHECKS[:]}
	state.machines[1] = {no = 4, name = "box", target = "box", status = .Online}
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
	testing.expect_value(t, core.handoff_short("/home/jb"), "~")
	testing.expect_value(t, core.handoff_short("/Users/jb/x/y"), "~/x/y")
	testing.expect_value(t, core.handoff_short("/root/api"), "~/api")
	testing.expect_value(t, core.handoff_short("/opt/api"), "/opt/api")
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
	testing.expect_value(t, toast.text, "No other machine has a project called api")
	testing.expect(t, !menu.open, "no menu")
	// another machine's project or Chats selected: not listed
	state.selected_project = 2
	testing.expect(t, !action_ok("new_session_elsewhere"), "not for Chats")
	state.selected_project = pid(3, 7)
	testing.expect(t, !action_ok("new_session_elsewhere"), "not for another machine's project")
}
