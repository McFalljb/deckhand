package main

// Saved and restored panes (persist.odin write_panes/panes_parse, panes_restore.odin;
// docs/PERSISTENCE.md "Panes"). Same rules as persist_test.odin: shared global State, one
// thread, harmless processes. Fixtures only, never a real workspace.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
pp_reset :: proc() -> runtime.Allocator {
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
	persist = {}
	platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("PI_DESK_CMD", "sleep 30")
	return runtime.heap_allocator()
}

@(private = "file")
pp_dir :: proc(tag: string) -> string {
	d := fmt.aprintf("%s/pi-desk-pp-%s-%d", os.get_env("TMPDIR", context.temp_allocator), tag, time.now()._nsec)
	os.make_directory_all(d)
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(d, context.temp_allocator), raw_data(buf[:]))
	return r != nil ? strings.clone(string(r)) : d
}

// A fake pi store under a temp HOME with session aaaa-1 in a new project folder; the folder.
@(private = "file")
pp_home :: proc() -> string {
	home, a := pp_dir("home"), pp_dir("a")
	name, _ := strings.replace_all(strings.trim_prefix(a, "/"), "/", "-", context.temp_allocator)
	dir := fmt.tprintf("%s/.pi/agent/sessions/--%s--", home, name)
	os.make_directory_all(dir)
	header := fmt.tprintf(`{{"type":"session","version":3,"id":"aaaa-1","cwd":"%s"}}`+"\n", a)
	_ = os.write_entire_file(fmt.tprintf("%s/2026-10-30T10-00-00-000Z_aaaa-1.jsonl", dir), transmute([]u8)header)
	os.set_env("HOME", home)
	return a
}

// A session's panes as text: a split is dir(ratio a b), a pane [its tabs' titles], * on the
// tab it shows, @ before the focused pane. "!" + the problem when session_check finds one.
@(private = "file")
pp_desc :: proc(s: ^Open_Session) -> string {
	if err := session_check(s); err != "" do return fmt.tprintf("!%s", err)
	b := strings.builder_make(context.temp_allocator)
	walk :: proc(b: ^strings.Builder, s: ^Open_Session, n: int) {
		x := s.nodes[n]
		if !x.leaf {
			fmt.sbprintf(b, "%s(%.3f ", x.dir == .Right ? "right" : "down", x.ratio)
			walk(b, s, x.a)
			strings.write_byte(b, ' ')
			walk(b, s, x.b)
			strings.write_byte(b, ')')
			return
		}
		p := session_pane(s, x.pane)
		if p.id == s.focused_pane do strings.write_byte(b, '@')
		strings.write_byte(b, '[')
		first := true
		for t in s.tabs do if t.pane == p.id {
			if !first do strings.write_byte(b, ',')
			first = false
			strings.write_string(b, t.title)
			if t.id == p.active do strings.write_byte(b, '*')
		}
		strings.write_byte(b, ']')
	}
	walk(&b, s, s.root)
	return strings.to_string(b)
}

// A workspace with one open session of project `a`: its saved tabs (after the pi tab), active
// tab and "panes" ("" = none). Not current: nothing starts.
@(private = "file")
pp_file :: proc(a, tabs: string, active: int, panes: string) -> string {
	p := panes != "" ? fmt.tprintf(`,"panes":%s`, panes) : ""
	return fmt.tprintf(`{{"v":1,"projects":[],"open_sessions":[{{"pi_session_id":"aaaa-1","cwd":%q,"session_dir":"","project":%q,"tabs":[{{"kind":"pi"}}%s],"active_tab":%d%s}}]}}`, a, a, tabs, active, p)
}

@(private = "file")
pp_restore :: proc(t: ^testing.T, text: string, loc := #caller_location) -> ^Open_Session {
	pp_reset()
	rescan_now()
	testing.expect_value(t, workspace_restore(text), "", loc)
	testing.expect_value(t, len(state.open_sessions), 1, loc)
	if len(state.open_sessions) != 1 do return nil
	return &state.open_sessions[0]
}

// Three shells after the pi tab: A, B, C.
@(private = "file")
pp_shells :: proc(a: string) -> string {
	return fmt.tprintf(`,{{"kind":"shell","title":"A","cwd":%q}},{{"kind":"shell","title":"B","cwd":%q}},{{"kind":"shell","title":"C","cwd":%q}}`, a, a, a)
}

// A file from before panes, and a file whose panes are not readable, restore as one pane with
// every tab, showing the saved active tab (today's behaviour); the restore never fails.
@(test)
panes_saved_old_and_corrupt_files :: proc(t: ^testing.T) {
	context.allocator = pp_reset()
	a := pp_home()
	one := "@[pi,A,B*,C]"
	s := pp_restore(t, pp_file(a, pp_shells(a), 2, ""))
	if s != nil do testing.expect_value(t, pp_desc(s), one)
	two := `{"split":"right","ratio":0.5,"a":{"pane":0},"b":{"pane":1}}`
	nine := `{"pane":0}`
	for i in 1 ..< 9 do nine = fmt.tprintf(`{{"split":"down","ratio":0.5,"a":%s,"b":{{"pane":%d}}}}`, nine, i)
	corrupt := []string {
		`7`,
		`[]`,
		`{}`, // no tree
		`{"tree":{"pane":0},"tab_pane":[0,0,0,0],"active":[2],"focused":0}`, // one pane
		`{"tree":[0,1],"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`,
		`{"tree":{"split":"right","ratio":0.5,"a":{"pane":0},"b":{"pane":0}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`, // a pane twice
		`{"tree":{"split":"right","ratio":0.5,"a":{"pane":0},"b":{"pane":2}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`, // pane 2 of 2
		`{"tree":{"split":"right","ratio":0.5,"a":{"pane":0},"b":{"pane":-1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`,
		`{"tree":{"split":"right","ratio":0.5,"a":{"pane":0}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`, // no b
		`{"tree":{"split":"sideways","ratio":0.5,"a":{"pane":0},"b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`,
		`{"tree":{"split":"right","ratio":"0.5","a":{"pane":0},"b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`,
		`{"tree":{"split":"right","a":{"pane":0},"b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`, // no ratio
		`{"tree":{"split":"right","ratio":0.5,"a":{"pane":"0"},"b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`,
		`{"tree":{"split":"right","ratio":0.5,"a":{"pane":0.0},"b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`,
		`{"tree":{"split":"right","ratio":0.5,"pane":0,"a":{"pane":0},"b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`, // a leaf and a split
		`{"tree":{"split":"right","ratio":0.5,"a":"x","b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":0}`,
		fmt.tprintf(`{{"tree":%s,"tab_pane":[0,1,2,3],"active":[0,1,2,3,0,0,0,0,0],"focused":0}}`, nine), // 9 panes: over PANES_MAX
	}
	_ = two
	for c in corrupt {
		s = pp_restore(t, pp_file(a, pp_shells(a), 2, c))
		if s != nil do testing.expectf(t, pp_desc(s) == one, "%s: %s", c, pp_desc(s))
		// and the next save has no panes
		testing.expectf(t, !strings.contains(workspace_json(), `"panes"`), "%s: saved again", c)
	}
}

// The repair rules, each on its own fixture.
@(test)
panes_saved_repairs :: proc(t: ^testing.T) {
	context.allocator = pp_reset()
	a := pp_home()
	right := `{"split":"right","ratio":0.5,"a":{"pane":0},"b":{"pane":1}}`
	Case :: struct {
		what, tabs: string,
		active:     int,
		panes, want: string,
	}
	cases := []Case {
		// the pi tab in pane 1, not the first leaf; the focused pane's shown tab is active_tab
		{"pi in pane 1", pp_shells(a), 2, `{"tree":{"split":"right","ratio":0.55,"a":{"pane":0},"b":{"pane":1}},"tab_pane":[1,0,0,1],"active":[2,0],"focused":0}`, "right(0.550 @[A,B*] [pi*,C])"},
		{"pi in pane 1, focused", pp_shells(a), 0, `{"tree":{"split":"right","ratio":0.55,"a":{"pane":0},"b":{"pane":1}},"tab_pane":[1,0,0,1],"active":[2,0],"focused":1}`, "right(0.550 [A,B*] @[pi*,C])"},
		// a pane's shown tab did not come back (a diff view is saved without a path): its first tab
		{"active dropped", fmt.tprintf(`,{{"kind":"shell","title":"A","cwd":%q}},{{"kind":"editor"}},{{"kind":"shell","title":"B","cwd":%q}}`, a, a), 2, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,1,1,1],"active":[0,2],"focused":1}}`, right), "right(0.500 [pi*] @[A*,B])"},
		// a pane whose only tab did not come back (an app tab, never restored): it goes, one pane is left
		{"only tab dropped", fmt.tprintf(`,{{"kind":"shell","title":"A","cwd":%q}},{{"kind":"app","app":"game"}}`, a), 2, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,0,1],"active":[1,2],"focused":1}}`, right), "@[pi,A*]"},
		// three panes, the middle one's only tab a URL that does not load: the tree closes over it
		{"nested, middle dropped", fmt.tprintf(`,{{"kind":"shell","title":"A","cwd":%q}},{{"kind":"browser","url":"javascript:alert(1)","title":"bad"}},{{"kind":"shell","title":"B","cwd":%q}}`, a, a), 3, `{"tree":{"split":"right","ratio":0.3,"a":{"pane":0},"b":{"split":"down","ratio":0.6,"a":{"pane":1},"b":{"pane":2}}},"tab_pane":[0,0,1,2],"active":[1,2,3],"focused":2}`, "right(0.300 [pi,A*] @[B*])"},
		{"nested, kept", pp_shells(a), 3, `{"tree":{"split":"right","ratio":0.3,"a":{"pane":0},"b":{"split":"down","ratio":0.6,"a":{"pane":1},"b":{"pane":2}}},"tab_pane":[0,0,1,2],"active":[1,2,3],"focused":2}`, "right(0.300 [pi,A*] down(0.600 [B*] @[C*]))"},
		// tabs whose pane is not a pane (or not a number) go to the focused pane
		{"unknown pane", pp_shells(a), 2, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,7,1,"x"],"active":[0,2],"focused":1}}`, right), "right(0.500 [pi*] @[A,B*,C])"},
		{"short tab_pane", pp_shells(a), 0, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,1],"active":[0,1],"focused":0}}`, right), "right(0.500 @[pi*,B,C] [A*])"},
		{"no tab_pane", pp_shells(a), 2, fmt.tprintf(`{{"tree":%s,"active":[0,2],"focused":0}}`, right), "@[pi,A,B*,C]"},
		// ratios out of range are clamped
		{"ratio high", pp_shells(a), 2, `{"tree":{"split":"right","ratio":1.7,"a":{"pane":0},"b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":1}`, "right(0.950 [pi*,A] @[B*,C])"},
		{"ratio low", pp_shells(a), 2, `{"tree":{"split":"down","ratio":-3,"a":{"pane":0},"b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":1}`, "down(0.050 [pi*,A] @[B*,C])"},
		{"ratio 1", pp_shells(a), 2, `{"tree":{"split":"right","ratio":1,"a":{"pane":0},"b":{"pane":1}},"tab_pane":[0,0,1,1],"active":[0,2],"focused":1}`, "right(0.950 [pi*,A] @[B*,C])"},
		// a focused pane that is not one: the first pane
		{"focused out of range", pp_shells(a), 2, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,0,1,1],"active":[1,2],"focused":5}}`, right), "right(0.500 @[pi,A*] [B*,C])"},
		{"no focused", pp_shells(a), 2, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,0,1,1],"active":[1,2]}}`, right), "right(0.500 @[pi,A*] [B*,C])"},
		{"first leaf is pane 1", pp_shells(a), 2, `{"tree":{"split":"right","ratio":0.5,"a":{"pane":1},"b":{"pane":0}},"tab_pane":[0,0,1,1],"active":[1,2]}`, "right(0.500 @[B*,C] [pi,A*])"},
		// a shown tab that is not one of the pane's tabs, or not a tab: the pane's first tab
		{"active in another pane", pp_shells(a), 2, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,0,1,1],"active":[2,2],"focused":1}}`, right), "right(0.500 [pi*,A] @[B*,C])"},
		{"active not a tab", pp_shells(a), 2, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,0,1,1],"active":[-1,9],"focused":1}}`, right), "right(0.500 [pi*,A] @[B*,C])"},
		{"no active", pp_shells(a), 2, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,0,1,1],"focused":1}}`, right), "right(0.500 [pi*,A] @[B*,C])"},
		// every tab in one pane: the other, empty, goes
		{"a pane with no tabs", pp_shells(a), 2, fmt.tprintf(`{{"tree":%s,"tab_pane":[0,0,0,0],"active":[2,0],"focused":1}}`, right), "@[pi,A,B*,C]"},
	}
	for c in cases {
		s := pp_restore(t, pp_file(a, c.tabs, c.active, c.panes))
		if s == nil do continue
		testing.expectf(t, pp_desc(s) == c.want, "%s: got %s, want %s", c.what, pp_desc(s), c.want)
		testing.expectf(t, s.tabs[0].title == "pi", "%s: the pi tab is not first", c.what)
	}
}

// A live layout saved and read back: tree, ratios, each tab's pane, each pane's shown tab and
// the focused pane, the pi tab in the second pane; the file the same after a second save; one
// pane saves no "panes" key.
@(test)
panes_saved_round_trip :: proc(t: ^testing.T) {
	context.allocator = pp_reset()
	a := pp_home()
	rescan_now()
	r := run_command(Open_Session_Cmd{project_id = state.projects[0].id, pi_session_id = "aaaa-1"})
	testing.expect(t, r.ok, r.error)
	sid := r.created_id
	for _ in 0 ..< 3 do run_command(New_Shell_Tab{session = sid})
	s := find_session(sid)
	sh1, sh2, sh3 := s.tabs[1].id, s.tabs[2].id, s.tabs[3].id
	single := strings.clone(workspace_json(), context.temp_allocator)
	testing.expect(t, !strings.contains(single, `"panes"`), single)
	// shell 1 splits off to the left: the pi tab's pane is the second leaf; shell 3 splits below it
	r = run_command(Split_Pane{pane = s.focused_pane, direction = .Left, tab_id = sh1})
	testing.expect(t, r.ok, r.error)
	left := r.created_id
	pi_pane := s.tabs[0].pane
	r = run_command(Split_Pane{pane = pi_pane, direction = .Down, tab_id = sh3})
	testing.expect(t, r.ok, r.error)
	// the ratios set directly: set_split reads the laid-out split from Clay (pane_ratio_kept),
	// which this test process never initialises
	for n in s.nodes do if !n.leaf && n.dir == .Right do pane_set_ratio(s, n.id, 0.3472)
	for n in s.nodes do if !n.leaf && n.dir == .Down do pane_set_ratio(s, n.id, 0.62)
	run_command(Focus_Tab{tab_id = sh2}) // pi's pane shows shell 2
	gen := persist.gen
	run_command(Focus_Pane{pane = left}) // the left pane has the keyboard
	testing.expect(t, persist.gen > gen, "a pane's focus is saved data")
	want := "right(0.347 @[shell 1*] down(0.620 [pi,shell 2*] [shell 3*]))"
	testing.expect_value(t, pp_desc(s), want)
	testing.expect_value(t, session_focused_tab(s).title, "shell 1")
	saved := strings.clone(workspace_json(), context.temp_allocator)
	testing.expectf(t, strings.contains(saved, `"tabs":[{"kind":"pi"},{"kind":"shell","title":"shell 2"`) && strings.contains(saved, `"active_tab":2,"panes":{"tree":{"split":"right","ratio":0.347,"a":{"pane":0},"b":{"split":"down","ratio":0.620,"a":{"pane":1},"b":{"pane":2}}},"tab_pane":[1,1,0,2],"active":[2,1,3],"focused":0}}`), "%s", saved)

	// after a restart: the same layout, the current session started in its focused pane
	pp_reset()
	rescan_now()
	testing.expect_value(t, workspace_restore(saved), "")
	persist_after_layout(skip = false)
	testing.expect_value(t, len(state.open_sessions), 1)
	if len(state.open_sessions) != 1 do return
	s = &state.open_sessions[0]
	testing.expect_value(t, pp_desc(s), want)
	testing.expect_value(t, session_focused_tab(s).title, "shell 1")
	testing.expect(t, s.tabs[0].title == "pi")
	testing.expect_value(t, state.current_session, s.id)
	for tab in s.tabs do testing.expect_value(t, tab.status, Tab_Status.Running)
	again := workspace_json()
	testing.expectf(t, again == saved, "second save differs:\n%s\n---\n%s", saved, again)
}

// A Claude-only session (its main Claude tab is tabs[0], with its own saved pane) and a chat
// keep their panes.
@(test)
panes_saved_claude_and_chat :: proc(t: ^testing.T) {
	context.allocator = pp_reset()
	a := pp_home()
	sid := "c4c4c4c4-0000-4000-8000-000000000001"
	text := fmt.tprintf(`{{"v":1,"projects":[],"open_sessions":[{{"agent":"claude","claude_session_id":%q,"pi_session_id":"","cwd":%q,"session_dir":"","project":%q,"tabs":[{{"kind":"claude","claude_session_id":%q,"cwd":%q}},{{"kind":"shell","title":"A","cwd":%q}}],"active_tab":0,"panes":{{"tree":{{"split":"right","ratio":0.4,"a":{{"pane":0}},"b":{{"pane":1}}}},"tab_pane":[1,0],"active":[1,0],"focused":1}}}}]}}`, sid, a, a, sid, a, a)
	s := pp_restore(t, text)
	if s != nil {
		testing.expect_value(t, pp_desc(s), "right(0.400 [A*] @[Claude*])")
		testing.expect_value(t, s.agent, Session_Agent.Claude)
		testing.expect(t, strings.contains(workspace_json(), `"tab_pane":[1,0],"active":[1,0],"focused":1`), workspace_json())
	}

	// a chat (in Chats): its panes come back with it
	old_root := home_root
	defer home_root = old_root
	home_root = pp_dir("chat-data")
	pp_reset()
	rescan_now()
	c := chats_project()
	if c == nil {
		testing.fail_now(t, "no Chats")
	}
	os.make_directory_all(c.cwd)
	text = fmt.tprintf(`{{"v":1,"open_sessions":[{{"pi_session_id":"chat-pi-1","cwd":%q,"session_dir":"","project":%q,"chat":true,"tabs":[{{"kind":"pi"}},{{"kind":"shell","title":"A","cwd":%q}}],"active_tab":1,"panes":{{"tree":{{"split":"down","ratio":0.5,"a":{{"pane":0}},"b":{{"pane":1}}}},"tab_pane":[0,1],"active":[0,1],"focused":1}}}}]}}`, c.cwd, c.cwd, c.cwd)
	testing.expect_value(t, workspace_restore(text), "")
	testing.expect_value(t, len(state.open_sessions), 1)
	if len(state.open_sessions) != 1 do return
	s = &state.open_sessions[0]
	testing.expect_value(t, s.project_id, c.id)
	testing.expect_value(t, pp_desc(s), "down(0.500 [pi*] @[A*])")
}
