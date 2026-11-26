package core

// The browser's "web" state section (web_view.odin): its rows from State, and that it is computed
// again only when something it reads changed. Same rules as core_test.odin: shared global State,
// one thread, no processes.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
web_view_section :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	p := Project{id = new_id(), group = .Projects, cwd = "/tmp/web-view-alpha"}
	append(&state.projects, p)
	s := Open_Session{id = new_id(), project_id = p.id, pi_session_id = "pi-alpha", cwd = p.cwd}
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running, agent = .Idle, waiting = true})
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)

	// the sections: the small part, the open session's row, the tree and its row
	sec :: proc(list: [][2]string, name: string) -> (string, bool) {
		for x in list do if x[0] == name do return x[1], true
		return "", false
	}
	parse :: proc(j: string) -> json.Value {
		v, err := json.parse_string(j, allocator = context.temp_allocator)
		if err != nil do return nil
		return v
	}
	secs := state_sections(&state)
	out := web_view_cached(secs[:])
	snap := make(map[string]string, context.temp_allocator)
	for x in out do snap[strings.clone(x[0], context.temp_allocator)] = strings.clone(x[1], context.temp_allocator) // the cache frees its own on a recompute
	w, _ := sec(out, "web")
	o := parse(w).(json.Object)
	open := o["open"].(json.Array)
	testing.expect_value(t, len(open), 1)
	testing.expect_value(t, u64(open[0].(json.Float)), s.id)
	testing.expect_value(t, int(o["fleet"].(json.Object)["waiting"].(json.Float)), 1)
	ws, has := sec(out, fmt.tprintf("webo:%d", s.id))
	testing.expect(t, has, "the open session's row")
	ti := parse(ws).(json.Object)
	testing.expect_value(t, ti["title"].(json.String), "Untitled session")
	testing.expect_value(t, ti["place"].(json.String), "web-view-alpha")
	testing.expect_value(t, ti["at"].(json.Float), 0)
	tree, _ := sec(out, "webtree")
	testing.expect_value(t, tree, fmt.tprintf(`["%d"]`, p.id))
	row, _ := sec(out, fmt.tprintf("webp:%d", p.id))
	testing.expect_value(t, parse(row).(json.Object)["path"].(json.String), "/tmp/web-view-alpha")

	// unchanged inputs: not computed again; a status flip: computed again, and of the browser's
	// sections only the small one changed (no tree row, no title row)
	n := web_view_last.builds
	_ = web_view_cached(secs[:])
	testing.expect_value(t, web_view_last.builds, n)
	state.open_sessions[0].tabs[0].waiting = false
	secs2 := state_sections(&state)
	out2 := web_view_cached(secs2[:])
	testing.expect_value(t, web_view_last.builds, n + 1)
	changed := make([dynamic]string, context.temp_allocator)
	for x in out2 do if snap[x[0]] != x[1] do append(&changed, x[0])
	// the small part and the session's status marks (webst)
	testing.expect_value(t, len(changed), 2)
	if len(changed) == 2 {
		testing.expect_value(t, changed[0], "web")
		testing.expect_value(t, changed[1], fmt.tprintf("webst:%d", s.id))
	}
	// a session file's new stamp (web_view_tick's read) is a change even with the sections alike
	state.open_sessions[0].mtime._nsec = 1_700_000_000_000_000_000
	_ = web_view_cached(secs2[:])
	testing.expect_value(t, web_view_last.builds, n + 2)

	// web_watch: a browser's only
	r := run_command(Web_Watch{projects = {p.id}}, Caller{kind = .UI})
	testing.expect(t, !r.ok && r.error != "", "refused for the window")
	state = State{}
}

// The New session picker's choices a browser gets ("web".new): the native picker's
// (new_session_choices) per machine and kind of project, one row per harness, the last used first;
// a change of what is installed computes the section again.
@(test)
web_view_new_choices_section :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	// never the developer's own Claude or Codex folders
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer os.set_env("HOME", old_home)
	home := fmt.tprintf("%s/deckhand-web-new-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec)
	os.make_directory_all(home)
	defer os.remove_all(home)
	os.set_env("HOME", home)
	os.unset_env("CLAUDE_CONFIG_DIR")
	harness_installed_probe[.Pi] = proc() -> bool {return true}
	harness_installed_probe[.Claude] = proc() -> bool {return true}
	harness_installed_probe[.Codex] = proc() -> bool {return false}
	defer harness_installed_probe[.Pi], harness_installed_probe[.Claude], harness_installed_probe[.Codex] = nil, nil, nil
	state.settings.last_harness = .Claude
	checks := []Machine_Check{{id = "pi", state = .Ok}, {id = "claude", state = .Too_Old}, {id = "codex", state = .Ok}}
	machines := []Machine_View{{no = 2, name = "m2", checklist = checks, codex = true}, {no = 3, name = "m3", checklist = checks[2:]}}
	state.machines = machines

	new_of :: proc() -> string {
		secs := state_sections(&state)
		for x in web_view_cached(secs[:]) do if x[0] == "web" {
			v, err := json.parse_string(x[1], allocator = context.temp_allocator)
			if err != nil do return "bad json"
			b := strings.builder_make(context.temp_allocator)
			for m in v.(json.Object)["new"].(json.Array) {
				o := m.(json.Object)
				fmt.sbprintf(&b, "%d:", int(o["machine"].(json.Float)))
				for kind in ([]string{"projects", "chats"}) {
					strings.write_string(&b, " ")
					for c, i in o[kind].(json.Array) {
						if i > 0 do strings.write_byte(&b, ',')
						fmt.sbprintf(&b, "%s=%s", c.(json.Object)["harness"].(json.String), c.(json.Object)["label"].(json.String))
					}
					strings.write_string(&b, " |")
				}
				fmt.sbprintf(&b, " tabs %d/%d", len(o["claude_tab"].(json.Array)), len(o["codex_tab"].(json.Array)))
				if strings.contains(o["note"].(json.String), CODEX_REMOTE) do strings.write_string(&b, " (codex note)") // the remote core too old for Codex (NO_HARNESS names Codex too)
				strings.write_byte(&b, '\n')
			}
			return strings.to_string(b)
		}
		return "no web section"
	}
	// here: Claude Code first (the last used), in Chats too; m2: Codex while its core starts it, never
	// Claude Code or Codex in its Chats; m3: Codex there but its core too old: none, and why
	testing.expect_value(t, new_of(), "0: claude=Claude Code,pi=pi | claude=Claude Code,pi=pi | tabs 1/0\n2: claude=Claude Code,pi=pi,codex=Codex | pi=pi | tabs 1/1\n3:  |  | tabs 0/0 (codex note)\n")
	// Codex installed here (no other section changes): offered at once, in Chats too
	harness_installed_probe[.Codex] = proc() -> bool {return true}
	testing.expect(t, strings.has_prefix(new_of(), "0: claude=Claude Code,pi=pi,codex=Codex | claude=Claude Code,pi=pi,codex=Codex | tabs 1/1\n"), new_of())
	harness_installed_probe[.Pi] = proc() -> bool {return false}
	testing.expect(t, strings.has_prefix(new_of(), "0: claude=Claude Code,codex=Codex | claude=Claude Code,codex=Codex | tabs 1/1\n"), new_of())
	// a browser's new session goes first next time (as the native picker's); an agent's does not
	web_note_harness(New_Claude_Session{project_id = 1, harness = .Codex}, {kind = .UI, web = true})
	testing.expect_value(t, state.settings.last_harness, Harness.Codex)
	testing.expect(t, strings.has_prefix(new_of(), "0: codex=Codex,claude=Claude Code | codex=Codex,claude=Claude Code |"), new_of())
	web_note_harness(New_Chat{project_id = 1}, {kind = .Control, web = false})
	web_note_harness(New_Chat{project_id = 1}, {kind = .UI})
	web_note_harness(Close_Tab{tab_id = 1}, {kind = .UI, web = true})
	testing.expect_value(t, state.settings.last_harness, Harness.Codex)
	web_note_harness(New_Chat{project_id = 1}, {kind = .UI, web = true})
	testing.expect_value(t, state.settings.last_harness, Harness.Pi)
}

// A browser's status strip ("webbars": tab_bars.odin): the native bars' text per tab, with only the
// actions a browser may take (a command it may send, copying text, its Settings screen); the
// hot-reload bars once for every tab of their harness; another machine's tabs none.
@(test)
web_view_bars_section :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	p := Project{id = new_id(), group = .Projects, cwd = "/tmp/web-bars"}
	append(&state.projects, p)
	s := Open_Session{id = new_id(), project_id = p.id, pi_session_id = "pi-bars", cwd = p.cwd}
	ct := Claude_Tab{harness = .Claude}
	append(&ct.held, Claude_Held{id = 1, text = "deploy\tit\nnow ‮" + "please", who = "Atlas"})
	claude := Tab{id = new_id(), kind = ct, title = "Claude", status = .Running}
	pi := Tab{id = new_id(), kind = Pi_Tab{}, title = "pi", status = .Running}
	pi.reload.version = "1.0.0" // older than PI_MIN_VERSION
	append(&s.tabs, claude, pi)
	s.active_tab = claude.id
	append(&state.open_sessions, s)
	state.reload.from_save = true // pi settings saved: the reload bar shows
	v, err := json.parse_string(web_bars_json(), allocator = context.temp_allocator)
	testing.expect(t, err == nil, "JSON")
	bars := v.(json.Array)
	b := strings.builder_make(context.temp_allocator)
	for x in bars {
		o := x.(json.Object)
		fmt.sbprintf(&b, "%s/%s/%s tab=%v:", o["harness"].(json.String), o["kind"].(json.String), o["tone"].(json.String), o["tab"].(json.Float) != 0)
		for a in o["actions"].(json.Array) {
			ao := a.(json.Object)
			what := "settings"
			if c, is := ao["command"].(json.Object); is do what = string(c["type"].(json.String))
			else if c, is := ao["copy"].(json.String); is do what = fmt.tprintf("copy %s", c)
			fmt.sbprintf(&b, " [%s %s]", ao["label"].(json.String), what)
		}
		strings.write_byte(&b, '\n')
	}
	got := strings.to_string(b)
	testing.expect_value(t, got, fmt.tprintf("claude/held/waiting tab=true: [Drop claude_held] [Send now claude_held]\npi/status/waiting tab=true: [Copy update command copy %s]\npi/reload/info tab=false: [Later pi_reload_later]\n", PI_UPDATE_COMMAND))
	held := bars[0].(json.Object)["text"].(json.String)
	testing.expect(t, strings.has_prefix(held, "1 message from Atlas waits: ") && strings.contains(held, "“deploy it now please”"), held)
	testing.expect(t, !strings.contains(held, "‮") && !strings.contains_any(held, "\t\n"), "the preview is one plain line")
	// another machine's tabs: their own core's bars
	state.open_sessions[0].machine = 2
	state.reload.from_save = false
	testing.expect_value(t, web_bars_json(), "[]")
}

// A browser's filter and quick filters are its own (#196): set_filter from a browser narrows the
// browser's tree and leaves the window's (state.sidebar) as it is; the window's never narrows the
// browser's. Show hidden stays one setting.
@(test)
web_view_own_filter :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	defer web_filters_reset()
	a := Project{id = new_id(), group = .Projects, cwd = "/tmp/web-filter-alpha"}
	b := Project{id = new_id(), group = .Projects, cwd = "/tmp/web-filter-beta"}
	append(&state.projects, a, b)
	BROWSER :: Caller{kind = .UI, web = true}
	tree_and_filter :: proc() -> (tree, filter: string) {
		secs := state_sections(&state)
		for x in web_view_cached(secs[:]) {
			if x[0] == "webtree" do tree = strings.clone(x[1], context.temp_allocator)
			if x[0] == "web" {
				v, _ := json.parse_string(x[1], allocator = context.temp_allocator)
				f := v.(json.Object)["filter"].(json.Object)
				filter = fmt.tprintf("%s|%v|%v|%v", f["text"].(json.String), f["running"].(json.Boolean), f["waiting"].(json.Boolean), f["pinned"].(json.Boolean))
			}
		}
		return
	}
	both := fmt.tprintf(`["%d","%d"]`, a.id, b.id)
	tree, filter := tree_and_filter()
	testing.expect_value(t, tree, both)
	testing.expect_value(t, filter, "|false|false|false")
	// the browser's: its tree narrows, the window's filter stays
	r := run_command(Set_Filter{text = "alpha", pinned = true}, BROWSER)
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.sidebar.filter, "")
	testing.expect(t, !state.sidebar.only_pinned, "the window's quick filter stays off")
	run_command(Set_Filter{pinned = false}, BROWSER)
	tree, filter = tree_and_filter()
	testing.expect_value(t, tree, fmt.tprintf(`["%d"]`, a.id))
	testing.expect_value(t, filter, "alpha|false|false|false")
	// the window's: its own, the browser's tree as it was
	testing.expect(t, run_command(Set_Filter{text = "beta", running = true}, Caller{kind = .UI}).ok)
	testing.expect_value(t, state.sidebar.filter, "beta")
	testing.expect(t, state.sidebar.only_running)
	tree, filter = tree_and_filter()
	testing.expect_value(t, tree, fmt.tprintf(`["%d"]`, a.id))
	testing.expect_value(t, filter, "alpha|false|false|false")
	testing.expect_value(t, state.sidebar.filter, "beta") // the build put the window's back
	// cleared in the browser: both its rows again, the window's filter still "beta"
	testing.expect(t, run_command(Set_Filter{text = "", running = false, waiting = false, pinned = false}, BROWSER).ok)
	tree, _ = tree_and_filter()
	testing.expect_value(t, tree, both)
	testing.expect_value(t, state.sidebar.filter, "beta")
	// Show hidden is one setting (saved), from either
	testing.expect(t, run_command(Set_Filter{show_hidden = true}, BROWSER).ok)
	testing.expect(t, state.sidebar.show_hidden)
}

// Atlas's button in a browser before Atlas's first start (#196): "web".atlas is atlas_offered (pi
// installed, or Atlas open or running), so a phone can start it (start_home) with no Home yet.
@(test)
web_view_atlas_offered :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	defer harness_installed_probe[.Pi] = nil
	atlas :: proc() -> string {
		secs := state_sections(&state)
		for x in web_view_cached(secs[:]) do if x[0] == "web" {
			v, _ := json.parse_string(x[1], allocator = context.temp_allocator)
			b, ok := v.(json.Object)["atlas"].(json.Boolean)
			return ok ? fmt.tprintf("%v", b) : "missing"
		}
		return "no web section"
	}
	harness_installed_probe[.Pi] = proc() -> bool {return true}
	testing.expect_value(t, atlas(), "true")
	harness_installed_probe[.Pi] = proc() -> bool {return false}
	testing.expect_value(t, atlas(), "false")
}

// A browser's set_filter is its sender's (#198 review): the device rides on the Caller, so a command
// still queued when another browser (or the window) takes the view never lands on that one.
@(test)
web_view_filter_is_the_senders :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	defer web_filters_reset()
	a := Project{id = new_id(), group = .Projects, cwd = "/tmp/web-sender-alpha"}
	b := Project{id = new_id(), group = .Projects, cwd = "/tmp/web-sender-beta"}
	append(&state.projects, a, b)
	A := Caller{kind = .UI, web = true, web_device = web_device_key("device-a")}
	testing.expect(t, A.web_device != 0)
	testing.expect(t, run_command(Set_Filter{text = "alpha"}, A).ok)
	testing.expect_value(t, web_filters[A.web_device].text, "alpha")
	// the view now (no browser attached here: another device's): not narrowed by A's filter
	testing.expect_value(t, web_filter_now().text, "")
	secs := state_sections(&state)
	for x in web_view_cached(secs[:]) do if x[0] == "webtree" do testing.expect_value(t, x[1], fmt.tprintf(`["%d","%d"]`, a.id, b.id))
	testing.expect_value(t, state.sidebar.filter, "") // nor the window's
}

// The status dots and marks a browser shows (#195 item 4), row for row as web/tests/status.test.ts
// pins the page's own reading: the core's tab_status_view and status_mark give the same, but for
// the two rows the page read differently (a pi tab with both the bridge and OSC 7501).
Web_Status_Case :: struct {
	row:      string,
	tab:      Tab,
	dot:      Row_Status,
	mark:     Status_Mark,
	progress: int, // percent, -1 none
}

web_status_cases :: proc() -> []Web_Status_Case {
	pi :: proc(t: Tab) -> Tab {t := t; t.kind = Pi_Tab{}; return t}
	sh :: proc(t: Tab) -> Tab {t := t; t.kind = Shell_Tab{}; return t}
	cl :: proc(ct: Claude_Tab, t: Tab = {}) -> Tab {t := t; t.kind = ct; return t}
	blocked :: proc(k: Prog_Kind) -> Prog_Summary {return {state = .Blocked, kind = k, progress = -1}}
	working :: proc(p: i8) -> Prog_Summary {return {state = .Working, progress = p}}
	cases := [?]Web_Status_Case {
		{"shell, nothing reported", sh({}), .None, .Idle, -1},
		{"pi idle", pi({agent = .Idle}), .None, .Idle, -1},
		{"pi working", pi({agent = .Working}), .Running, .Working, -1},
		{"pi waiting", pi({agent = .Idle, waiting = true}), .Waiting, .Waiting, -1},
		{"pi asked a question", pi({agent = .Idle, question = true}), .Question, .Question, -1},
		{"pi error", pi({agent = .Error}), .Error, .Error, -1},
		{"pi exited", pi({status = .Exited, agent = .Idle}), .Exited, .Exited, -1},
		{"pi finished, not seen", pi({agent = .Idle, unseen = true}), .Unseen, .Done, -1},
		{"pi not reporting yet", pi({}), .None, .Idle, -1},
		{"shell blocked: permission", sh({prog = blocked(.Permission)}), .Waiting, .Permission, -1},
		{"shell blocked: question", sh({prog = blocked(.Question)}), .Waiting, .Question, -1},
		{"shell blocked: auth", sh({prog = blocked(.Auth)}), .Waiting, .Auth, -1},
		{"shell blocked", sh({prog = blocked(.None)}), .Waiting, .Waiting, -1},
		{"shell working at 40%", sh({prog = working(40)}), .Running, .Progress, 40},
		{"shell working", sh({prog = working(-1)}), .Running, .Working, -1},
		{"shell error", sh({prog = {state = .Error, progress = -1}}), .Error, .Error, -1},
		{"shell done", sh({prog = {state = .Done, progress = -1}}), .None, .Idle, -1},
		{"pi exited, OSC 7501 done", pi({status = .Exited, prog = {state = .Done, progress = -1}}), .Exited, .Exited, -1},
		{"claude turn working", cl({turn = .Working}), .Running, .Working, -1},
		{"claude turn waiting", cl({turn = .Waiting}), .Waiting, .Waiting, -1},
		{"claude ended on a question", cl({turn = .Idle, ended = .Question}), .Question, .Question, -1},
		{"claude ended on an error", cl({turn = .Idle, ended = .Error}), .Error, .Error, -1},
		{"claude exited mid-turn", cl({turn = .Working}, {status = .Exited}), .None, .Idle, -1},
		{"claude: OSC 7501 over the hooks", cl({turn = .Waiting}, {prog = working(-1)}), .Running, .Working, -1},
		{"shell unseen under working", sh({unseen = true, prog = working(-1)}), .Running, .Working, -1},
		{"shell unseen", sh({unseen = true}), .Unseen, .Done, -1},
		// the page's own reading differed (web/tests/status.test.ts STATUS_DIFFERS): the bridge speaks
		{"pi waiting, OSC 7501 permission", pi({agent = .Idle, waiting = true, prog = blocked(.Permission)}), .Waiting, .Waiting, -1},
		{"pi working, OSC 7501 at 40%", pi({agent = .Working, prog = working(40)}), .Running, .Working, -1},
		// what it waits for: OSC 7501's message while OSC 7501 speaks, never under the bridge's dot
		{"shell blocked, a message", sh({prog = {state = .Blocked, kind = .Permission, progress = -1, msg = "Run rm?"}}), .Waiting, .Permission, -1},
		{"pi waiting, OSC 7501 with a message", pi({agent = .Idle, waiting = true, prog = {state = .Blocked, kind = .Permission, progress = -1, msg = "Run rm?"}}), .Waiting, .Waiting, -1},
		{"shell working, a message", sh({prog = {state = .Working, progress = -1, msg = "Building"}}), .Running, .Working, -1},
	}
	return slice_clone_temp(cases[:])
}

@(private = "file")
slice_clone_temp :: proc(x: []Web_Status_Case) -> []Web_Status_Case {
	out := make([]Web_Status_Case, len(x), context.temp_allocator)
	copy(out, x)
	return out
}

@(test)
web_view_status_table :: proc(t: ^testing.T) {
	for c in web_status_cases() {
		v := tab_status_view(c.tab)
		testing.expectf(t, v.dot == c.dot, "%s: dot %v, want %v", c.row, v.dot, c.dot)
		testing.expectf(t, status_mark(v) == c.mark, "%s: mark %v, want %v", c.row, status_mark(v), c.mark)
		pct := v.progress < 0 ? -1 : int(v.progress * 100 + 0.5)
		testing.expectf(t, pct == c.progress, "%s: progress %d, want %d", c.row, pct, c.progress)
	}

	// and as a browser gets them: webst:<session>, each tab's [dot, mark, progress], and the tab
	// the session's row shows (the strongest, the first of equals)
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	p := Project{id = new_id(), group = .Projects, cwd = "/tmp/web-view-status"}
	append(&state.projects, p)
	s := Open_Session{id = new_id(), project_id = p.id, pi_session_id = "pi-status", cwd = p.cwd}
	cases := web_status_cases()
	for &c in cases {
		c.tab.id = new_id()
		append(&s.tabs, c.tab)
	}
	s.active_tab = s.tabs[0].id
	append(&state.open_sessions, s)
	secs := state_sections(&state)
	out := web_view_cached(secs[:])
	j := ""
	for x in out do if x[0] == fmt.tprintf("webst:%d", s.id) do j = x[1]
	v, err := json.parse_string(j, allocator = context.temp_allocator)
	testing.expect(t, err == nil, "webst parses")
	if err != nil do return
	o := v.(json.Object)
	tabs := o["tabs"].(json.Object)
	for c in cases {
		row, has := tabs[fmt.tprintf("%d", c.tab.id)]
		testing.expectf(t, has, "%s: in webst", c.row)
		if !has do continue
		a := row.(json.Array)
		testing.expectf(t, a[0].(json.String) == ROW_STATUS_NAMES[c.dot], "%s: webst dot %v", c.row, a[0])
		testing.expectf(t, a[1].(json.String) == STATUS_MARK_NAMES[c.mark], "%s: webst mark %v", c.row, a[1])
		testing.expectf(t, int(a[2].(json.Float)) == c.progress, "%s: webst progress %v", c.row, a[2])
		// [3]: what it waits for, only while waiting and only OSC 7501's (the window's ui_sidebar.odin)
		want_msg := c.row == "shell blocked, a message" ? "Run rm?" : ""
		testing.expectf(t, len(a) == 4 && a[3].(json.String) == want_msg, "%s: webst msg %v, want %q", c.row, a, want_msg)
	}
	// the strongest: a waiting tab (rank 6), the first of them ("pi waiting")
	want: u64
	for c in cases do if c.row == "pi waiting" do want = c.tab.id
	testing.expect_value(t, u64(o["from"].(json.Float)), want)
}

@(test)
web_view_status_none :: proc(t: ^testing.T) {
	// a session with nothing to show: from 0, every tab idle
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	defer state = State{}
	s := Open_Session{id = new_id(), pi_session_id = "pi-quiet"}
	append(&s.tabs, Tab{id = new_id(), kind = Shell_Tab{}, prog = {progress = -1}})
	append(&s.tabs, Tab{id = new_id(), kind = Pi_Tab{}, agent = .Idle})
	append(&state.open_sessions, s)
	secs := state_sections(&state)
	out := web_view_cached(secs[:])
	j := ""
	for x in out do if x[0] == fmt.tprintf("webst:%d", s.id) do j = x[1]
	testing.expect_value(t, j, fmt.tprintf(`{{"from":0,"tabs":{{"%d":["none","idle",-1],"%d":["none","idle",-1]}}}}`, s.tabs[0].id, s.tabs[1].id))
}
