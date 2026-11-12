package main

// Layout audit: the real chrome laid out (Clay, system fonts, no window) at
// several window widths, in every look, light and dark, with the left and
// right columns on and off, on the Sessions and Files tabs, with an editor
// tab, a Markdown tab (and its preview's own layout: markdown_preview_audit),
// and with the settings popover open. Every piece of text and every
// icon must stay clear of the others and inside the rows, buttons, bars and
// columns it sits in; text in a scrolling list counts only where the list
// shows it. The settings popover must be opaque, and no text of the right
// column may peek out half-covered beside it. Same rules as core_test.odin
// (one thread, harmless processes).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"

AUDIT_WIDTHS :: [?]f32{WINDOW_MIN_W, 1280, 1600, 2000}
AUDIT_H :: 860

@(private = "file")
Box :: struct {
	x0, y0, x1, y1: f32,
}

@(private = "file")
Piece :: struct {
	box:  Box,
	text: string, // "" for an icon
	z:    i16,
	clip: Maybe(Box), // the scrolling list it is drawn in
}

@(private = "file")
box_of :: proc(b: clay.BoundingBox) -> Box {return {b.x, b.y, b.x + b.width, b.y + b.height}}

@(private = "file")
meet :: proc(a, b: Box) -> Box {return {max(a.x0, b.x0), max(a.y0, b.y0), min(a.x1, b.x1), min(a.y1, b.y1)}}

@(private = "file")
empty :: proc(b: Box) -> bool {return b.x1 - b.x0 <= 0.5 || b.y1 - b.y0 <= 0.5}

// Inside, allowing half a pixel of rounding.
@(private = "file")
inside_box :: proc(a, b: Box) -> bool {return a.x0 >= b.x0 - 0.5 && a.y0 >= b.y0 - 0.5 && a.x1 <= b.x1 + 0.5 && a.y1 <= b.y1 + 0.5}

// The texts and icons of a layout, each cut to the scrolling list it is in
// (dropped when the list does not show it).
@(private = "file")
pieces :: proc(cmds: clay.ClayArray(clay.RenderCommand)) -> [dynamic]Piece {
	out := make([dynamic]Piece, context.temp_allocator)
	scissor: [dynamic]Box
	scissor.allocator = context.temp_allocator
	for i in 0 ..< cmds.length {
		cmd := &cmds.internalArray[i]
		b := box_of(cmd.boundingBox)
		#partial switch cmd.commandType {
		case .ScissorStart:
			append(&scissor, b)
		case .ScissorEnd:
			if len(scissor) > 0 do pop(&scissor)
		case .Text, .Custom:
			p := Piece{box = b, z = cmd.zIndex}
			if cmd.commandType == .Text {
				t := cmd.renderData.text
				if t.textColor.a == 0 do continue
				p.text = string(t.stringContents.chars[:t.stringContents.length])
				if strings.trim_space(p.text) == "" do continue
			} // icons count even while faded out: they take their room
			if len(scissor) > 0 {
				s := scissor[len(scissor) - 1]
				p.clip = s
				p.box = meet(b, s)
				if empty(p.box) do continue
			}
			append(&out, p)
		}
	}
	return out
}

// Elements whose content must stay inside them: rows, buttons, tabs, bars and
// columns (by id, with list indices tried until one is missing).
// Overlays (menus, the popover) are a layer of their own: their content is
// checked against their own rows only.
@(private = "file")
containers :: proc(overlay: bool) -> [dynamic]Box {
	out := make([dynamic]Box, context.temp_allocator)
	one :: proc(out: ^[dynamic]Box, name: string, index: u32 = 0) -> bool {
		d := clay.GetElementData(clay.ID(name, index))
		if d.found && d.boundingBox.width > 0 do append(out, box_of(d.boundingBox))
		return d.found
	}
	if overlay {
		for name in ([]string{"settings_pop", "menu", "wt_menu", "wtnote", "bell_pop", "bell_head", "bell_markall", "bell_clear", "bell_list", "setup_box", "setup_head", "setup_body", "setup_foot"}) do one(&out, name)
		for i in u32(0) ..< u32(len(Pop_Item)) do one(&out, "pop", i) // some rows show only at times (Reload pi): every id
		one(&out, "bell_grid_head")
		for i in u32(0) ..< 4 do one(&out, "bell_grid_row", i)
		for name in ([]string{"menurow", "wtrow", "wtmore", "wthead", "bellrow", "bell_group", "setupopt", "setupbtn"}) do for i in u32(0) ..< 64 do if !one(&out, name, i) && i > 16 do break
		return out
	}
	for name in ([]string{"sidebar", "sidebar_top", "lefttabs", "filter_box", "quick", "nav", "tabs", "ed_tools", "right", "centre", "files_head", "wt_switch", "files_filter_box", "rename_field", "new", "newchatrow", "waitingfiltered", "search", "homebutton", "confirm_bar", "bell", "bell_badge", "jobs_head", "jobs_list", "jobs_paused", "jobs_limits", "drawer_notes_line", "spage", "spnav", "spbody", "sp_search_box", "sp_edit_box"}) do one(&out, name)
	for name in ([]string{"open", "proj", "sess", "chat", "tab", "ed_tool", "chip", "lefttab", "filestool", "settool", "frow", "fcreate", "fmore", "freset", "freveal", "navhead", "showmore", "panelhead", "jobrow", "jobmore", "jobstool", "jobbtn", "joblimit", "spi", "spfile"}) {
		for i in u32(0) ..< 400 do if !one(&out, name, i) && i > 2 do break
	}
	return out
}

// Problems in the current layout, one line each.
// (Also machine_rows_test.odin's, for the narrowest sidebar.)
// within: only the pieces that start inside this element (the drawer's
// header) on its layer (z), checked against the element and its own
// controls (what lies beneath on another layer does not hold them); "" = all.
audit :: proc(cmds: clay.ClayArray(clay.RenderCommand), where_: string, w: f32, within := "", layer: i16 = 0, own: []string = nil) -> [dynamic]string {
	bad := make([dynamic]string, context.temp_allocator)
	ps := pieces(cmds)
	if within != "" {
		d := clay.GetElementData(clay.ID(within))
		if !d.found {
			append(&bad, fmt.tprintf("%s: no %s", where_, within))
			return bad
		}
		wb := box_of(d.boundingBox)
		kept := make([dynamic]Piece, context.temp_allocator)
		for p in ps do if p.z == layer && p.box.x0 + 0.5 >= wb.x0 && p.box.x0 + 0.5 <= wb.x1 && (p.box.y0 + p.box.y1) / 2 >= wb.y0 && (p.box.y0 + p.box.y1) / 2 <= wb.y1 do append(&kept, p)
		ps = kept
	}
	// nothing pushed out of the window (a row too wide for the top bar pushes the columns off)
	window := Box{0, 0, w, AUDIT_H}
	for p in ps do if !inside_box(p.box, window) do append(&bad, fmt.tprintf("%s: %s is outside the window (%.0f..%.0f)", where_, p.text != "" ? fmt.tprintf("%q", p.text) : "an icon", p.box.x0, p.box.x1))
	base, over := containers(false), containers(true)
	if within != "" {
		mine := make([dynamic]Box, context.temp_allocator)
		append(&mine, box_of(clay.GetElementData(clay.ID(within)).boundingBox))
		for name in own do if d := clay.GetElementData(clay.ID(name)); d.found && d.boundingBox.width > 0 do append(&mine, box_of(d.boundingBox))
		base, over = mine, mine
	}
	name :: proc(p: Piece) -> string {return p.text != "" ? fmt.tprintf("%q", p.text) : "an icon"}
	for p, i in ps {
		// overlaps between pieces drawn on the same layer
		for q in ps[i + 1:] {
			if p.z != q.z do continue
			m := meet(p.box, q.box)
			if !empty(m) && m.x1 - m.x0 > 1 && m.y1 - m.y0 > 1 {
				append(&bad, fmt.tprintf("%s: %s overlaps %s", where_, name(p), name(q)))
			}
		}
		// inside its row, button or column (in a list: where it shows)
		// inside every row, button, bar and column that holds its start (in a list: where it shows)
		x, y := p.box.x0 + 0.5, (p.box.y0 + p.box.y1) / 2
		for c0 in (p.z >= 8 ? over[:] : base[:]) {
			if x < c0.x0 || x > c0.x1 || y < c0.y0 || y > c0.y1 do continue
			c := c0
			if cl, in_list := p.clip.?; in_list do c = meet(c, cl)
			if !inside_box(p.box, c) {
				append(&bad, fmt.tprintf("%s: %s leaves its container (%.0f..%.0f, container %.0f..%.0f)", where_, name(p), p.box.x0, p.box.x1, c.x0, c.x1))
				break
			}
		}
	}
	// the settings popover (and the bell's): opaque, and nothing in the right
	// column beneath it peeks out beside it (over the centre it covers like any menu)
	for pop_name in ([]string{"settings_pop", "bell_pop"}) {
		d := clay.GetElementData(clay.ID(pop_name))
		if !d.found do continue
		pop := box_of(d.boundingBox)
		right: Box
		if r := clay.GetElementData(clay.ID("right")); r.found && state.layout.right_open do right = box_of(r.boundingBox)
		for i in 0 ..< cmds.length {
			cmd := &cmds.internalArray[i]
			if cmd.id == clay.ID(pop_name).id && cmd.commandType == .Rectangle && cmd.renderData.rectangle.backgroundColor.a < 255 {
				append(&bad, fmt.tprintf("%s: %s is not opaque", where_, pop_name))
			}
		}
		for p in ps {
			if p.z >= 8 || p.box.x0 < right.x0 || right.x1 == 0 do continue // the popover's own content; outside the right column
			m := meet(p.box, pop)
			if !empty(m) && !inside_box(p.box, pop) do append(&bad, fmt.tprintf("%s: %s peeks out from under %s", where_, name(p), pop_name))
		}
	}
	return bad
}

@(private = "file")
au_reset :: proc(data_dir: string) -> runtime.Allocator {
	context.allocator = runtime.heap_allocator()
	for _, t in core.terms {
		core.term_free(t)
		free(t)
	}
	clear(&core.terms)
	core.inbox_drain()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true, right_open = true},
	}
	core.persist = {}
	menu = {}
	core.home_root = data_dir
	core.platform = {quit = proc() {}}
	win_os = {set_clipboard = proc(s: string) {}}
	os.set_env("SHELL", "/bin/sh")
	os.set_env("DECKHAND_CMD", "sleep 30")
	return runtime.heap_allocator()
}

@(private = "file")
au_session :: proc(home, cwd, id, title: string, minute: int) {
	name, _ := strings.replace_all(strings.trim_prefix(cwd, "/"), "/", "-", context.temp_allocator)
	dir := fmt.tprintf("%s/.pi/agent/sessions/--%s--", home, name)
	os.make_directory_all(dir)
	os.make_directory_all(cwd)
	path := fmt.tprintf("%s/2026-10-30T10-%02d-00-000Z_%s.jsonl", dir, minute, id)
	text := fmt.tprintf(`{{"type":"session","version":3,"id":"%s","cwd":"%s"}}`+"\n", id, cwd)
	if title != "" do text = fmt.tprintf(`%s{{"type":"message","message":{{"role":"user","content":"%s"}}}}`+"\n", text, title)
	_ = os.write_entire_file(path, transmute([]u8)text)
}

// The sweep below in four parts (every fourth width/look/appearance), each a test of its own, so
// tests/unit.py runs them in parallel: together they are the whole sweep.
LAYOUT_PARTS :: 4
@(test)
layout_no_overlap_1 :: proc(t: ^testing.T) {layout_no_overlap(t, 0)}
@(test)
layout_no_overlap_2 :: proc(t: ^testing.T) {layout_no_overlap(t, 1)}
@(test)
layout_no_overlap_3 :: proc(t: ^testing.T) {layout_no_overlap(t, 2)}
@(test)
layout_no_overlap_4 :: proc(t: ^testing.T) {layout_no_overlap(t, 3)}

layout_no_overlap :: proc(t: ^testing.T, part: int) {
	root := fmt.tprintf("%s/pd-audit-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	os.make_directory_all(root)
	buf: [posix.PATH_MAX]u8
	if r := posix.realpath(strings.clone_to_cstring(root, context.temp_allocator), raw_data(buf[:])); r != nil do root = strings.clone(string(r), context.temp_allocator)
	home := fmt.tprintf("%s/home", root)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	os.set_env("HOME", home)
	defer os.set_env("HOME", old_home)
	context.allocator = au_reset(fmt.tprintf("%s/data", root))
	if !testing.expect(t, audit_ui(), "fonts") do return

	alpha := fmt.tprintf("%s/code/recipe-box", home)
	long := fmt.tprintf("%s/code/garden-planner-with-a-rather-long-folder-name-that-keeps-going", home)
	chats := fmt.tprintf("%s/Chats", home)
	au_session(home, alpha, "r1", "Import recipes from a CSV export", 1)
	au_session(home, alpha, "r2", "Why does the search index miss accents in titles and ingredient names and units?", 2)
	au_session(home, alpha, "r3", "", 3)
	for i in 4 ..< 14 do au_session(home, alpha, fmt.tprintf("r%d", i), fmt.tprintf("Session number %d with a fairly long title", i), i)
	// a title as long as titles.odin keeps (TITLE_MAX), with no spaces to break at
	au_session(home, alpha, "r14", strings.repeat("Averyveryverylongtitlewithoutanyspaces", 8, context.temp_allocator), 14)
	au_session(home, long, "g1", "Frost dates per planting zone", 5)
	au_session(home, chats, "c1", "What is the difference between a mutex and a semaphore, in practice?", 6)
	au_session(home, chats, "c2", "", 7)
	_ = os.write_entire_file(fmt.tprintf("%s/main.c", alpha), transmute([]u8)string("int main(void) {\n    return 0;\n}\n"))
	// alpha is a git repository with worktrees (the Files tab's checkout switcher)
	os.set_env("GIT_CONFIG_NOSYSTEM", "1")
	defer os.unset_env("GIT_CONFIG_NOSYSTEM")
	au_git :: proc(dir: string, args: ..string) {
		full := make([dynamic]string, context.temp_allocator)
		append(&full, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main")
		append(&full, ..args)
		core.git_run(dir, ..full[:])
	}
	au_git(alpha, "init", "-q")
	au_git(alpha, "add", "main.c")
	au_git(alpha, "commit", "-qm", "init")
	au_git(alpha, "branch", "-M", "main")
	wt_long := fmt.tprintf("%s/code/recipe-box-worktrees/import-recipes-from-a-csv-export-with-a-long-branch-name", home)
	au_git(alpha, "worktree", "add", "-q", "-b", "import-recipes-from-a-csv-export-with-a-long-branch-name", wt_long)
	_ = os.write_entire_file(fmt.tprintf("%s/main.c", wt_long), transmute([]u8)string("int main(void) { return 1; }\n"))
	au_git(alpha, "worktree", "add", "-q", "-b", "fix", fmt.tprintf("%s/code/recipe-box-fix", home))
	au_git(alpha, "worktree", "add", "-q", "--detach", fmt.tprintf("%s/code/recipe-box-detached", home), "HEAD")
	au_git(alpha, "branch", "search-accents-in-titles-and-ingredient-names-and-units")
	au_git(alpha, "branch", "topic")
	// pi's settings files for the Settings tab (a fake agent dir under the fake HOME)
	os.unset_env("PI_CODING_AGENT_DIR")
	os.unset_env("XDG_CONFIG_HOME")
	os.make_directory_all(fmt.tprintf("%s/.pi/agent/prompts", home))
	os.make_directory_all(fmt.tprintf("%s/.pi/agent/skills/a-skill-with-a-rather-long-name-that-keeps-going-on", home))
	os.make_directory_all(fmt.tprintf("%s/.pi/agent/extensions/an-extension-with-a-long-folder-name", home))
	_ = os.write_entire_file(fmt.tprintf("%s/.pi/agent/extensions/an-extension-with-a-long-folder-name/config.json", home), transmute([]u8)string("{}"))
	_ = os.write_entire_file(fmt.tprintf("%s/.pi/agent/skills/a-skill-with-a-rather-long-name-that-keeps-going-on/SKILL.md", home), transmute([]u8)string("# s"))
	_ = os.write_entire_file(fmt.tprintf("%s/.pi/agent/APPEND_SYSTEM.md", home), transmute([]u8)string("x"))
	for f in ([]string{"settings.json", "models.json", "keybindings.json", "mcp.json", "AGENTS.md", "SYSTEM.md"}) do _ = os.write_entire_file(fmt.tprintf("%s/.pi/agent/%s", home, f), transmute([]u8)string("{}"))
	core.rescan_now()
	pa, pl: u64
	for p in state.projects {
		if p.cwd == alpha do pa = p.id
		if p.cwd == long do pl = p.id
	}
	c := core.chats_project()
	if !testing.expect(t, pa != 0 && pl != 0 && c != nil, "projects and Chats scanned") do return
	core.run_command(core.Select_Project{pa}, {kind = .UI})
	core.run_command(core.Open_Session_Cmd{project_id = pl, pi_session_id = "g1"}, {kind = .UI})
	core.run_command(core.Open_Session_Cmd{project_id = c.id, pi_session_id = "c1"}, {kind = .UI})
	core.run_command(core.New_Chat{project_id = pa}, {kind = .UI})
	core.run_command(core.Open_Session_Cmd{project_id = pa, pi_session_id = "r2"}, {kind = .UI})
	core.run_command(core.New_Shell_Tab{session = core.cur().id}, {kind = .UI})
	if wr := core.wt_repo_for(alpha); wr != nil {
		for _ in 0 ..< 1000 {
			core.inbox_drain()
			if wr.loaded && !wr.loading do break
			time.sleep(10 * time.Millisecond)
		}
		testing.expect(t, len(wr.checkouts) == 4, "worktrees scanned")
	}
	// the Changes tab of the long-named worktree (ui_changes.odin): a commit ahead of
	// main, uncommitted changes with long names, a staged file, an untracked one
	_ = os.write_entire_file(fmt.tprintf("%s/added-in-the-branch.c", wt_long), transmute([]u8)string("int x;\n"))
	au_git(wt_long, "add", "added-in-the-branch.c")
	au_git(wt_long, "-c", "user.name=t", "-c", "user.email=t@example.invalid", "commit", "-qm", "branch work")
	os.make_directory_all(fmt.tprintf("%s/src/importers/csv-with-a-rather-long-folder-name", wt_long))
	_ = os.write_entire_file(fmt.tprintf("%s/src/importers/csv-with-a-rather-long-folder-name/parse-the-recipe-rows-and-units.c", wt_long), transmute([]u8)string("int y;\n"))
	_ = os.write_entire_file(fmt.tprintf("%s/staged.c", wt_long), transmute([]u8)string("int z;\n"))
	au_git(wt_long, "add", "staged.c")
	// in g1's session (its own tabs: the pi tab only), so r2's tab strip stays as it was
	ch_session := open_session_of(pl, "g1")
	r := core.run_command(core.Changes_Open{session = ch_session, path = wt_long}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	ch_tab := r.created_id
	if cr := core.changes_repo(wt_long); cr != nil {
		for _ in 0 ..< 1000 {
			core.changes_ask(cr)
			core.changes_tick()
			core.inbox_drain()
			if v := core.changes_view(ch_tab); cr.loaded && !cr.loading && v != nil && !v.diff_loading do break
			time.sleep(10 * time.Millisecond)
		}
		testing.expect(t, cr.loaded && len(cr.files) >= 4, "the changes scanned")
	}
	if v := core.changes_view(ch_tab); v != nil {
		v.notice = strings.clone("git commit failed: pre-commit: lint found 3 problems in src/importers/csv-with-a-rather-long-folder-name/parse.c and more")
		v.notice_err = true
		v.diff_lines = 12000 // "Show more" shows
	}
	// a Markdown tab in g1's session too (its toolbar, preview and source)
	md_file := fmt.tprintf("%s/NOTES.md", alpha)
	_ = os.write_entire_file(md_file, transmute([]u8)string(MD_AUDIT_DOC))
	r = core.run_command(core.Markdown_Open{path = md_file, session = ch_session}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	md_tab := r.created_id
	core.run_command(core.Focus_Session{session = open_session_of(pa, "r2")}, {kind = .UI})
	r = core.run_command(core.Open_File{path = fmt.tprintf("%s/main.c", alpha)}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	// Atlas's drawer (shown below): a long model id, a working status
	r = core.run_command(core.Set_Home{open = true}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	core.run_command(core.Set_Home{open = false}, {kind = .UI})
	state.focus_widget = ""
	core.run_command(core.Set_Agent_Model{model = "opencode-go/muse-spark-1.2-contributor-with-a-rather-long-model-id"}, {kind = .UI})
	for d in ([]string{"skills", "skills/a-skill-with-a-rather-long-name-that-keeps-going-on", "extensions"}) {
		r = core.run_command(core.Files_Expand{path = fmt.tprintf("%s/.pi/agent/%s", home, d), expanded = true}, {kind = .UI})
		testing.expect(t, r.ok, r.error)
	}

	// status marks (status_marks_test.odin): r2's shell waits for a yes or no with a long
	// question for 3 minutes (its tab's mark, its open row's "3m · …"), g1's pi works at 40%
	if rs := core.find_session(open_session_of(pa, "r2")); rs != nil {
		for &tb in rs.tabs do if _, is := tb.kind.(core.Shell_Tab); is {
			tb.prog = {state = .Blocked, kind = .Permission, progress = -1, app = strings.clone("claude-code"), msg = strings.clone("Apply these edits to every file under src/importers and the folders with long names?")}
			tb.status_key = core.status_key(core.tab_status_view(tb))
			tb.status_since = time.time_add(time.now(), -3 * time.Minute)
		}
	}
	if gs := core.find_session(open_session_of(pl, "g1")); gs != nil {
		gs.tabs[0].prog = {state = .Working, progress = 40}
		gs.tabs[0].status_key = core.status_key(core.tab_status_view(gs.tabs[0]))
		gs.tabs[0].status_since = time.time_add(time.now(), -75 * time.Minute)
	}
	// the bell: entries of every kind (unread ones: the button's count), one
	// from yesterday (the Earlier group), long titles
	{
		gs := core.find_session(open_session_of(pl, "g1"))
		testing.expect(t, gs != nil, "g1 is open")
		if gs != nil {
			core.notice_test_now = time.now()
			defer core.notice_test_now = {}
			for k in ([]core.Notice_Kind{.Error, .Exited, .Waiting, .Finished}) {
				core.notice_test_now._nsec += i64(11 * time.Second) // past coalescing: each its own entry
				core.notify_session(gs, &gs.tabs[0], k)
			}
			for st in core.Job_Status {
				core.run_command(core.Notify_Post{job = {job_id = fmt.tprintf("nightly-%v", st), title = "Nightly dependency audit across every project with a long name", status = st, summary = "3 advisories, 1 needs a decision about the lockfile and the pinned versions", run_dir = "/tmp/x"}})
				core.inbox_drain()
			}
			state.notices.items[0].at._nsec -= i64(36 * time.Hour)
			state.notices.items[1].read = true
		}
	}
	testing.expect(t, core.notices_unread() >= 6, "bell entries for the audit")
	// the Jobs tab: a notes folder and rows of every kind (long names, an
	// error, a change to review, needs you, unread, run lines)
	saved_notes := state.settings.home_dir
	state.settings.home_dir = strings.clone(fmt.tprintf("%s/notes-in-a-folder-with-a-long-name", root))
	os.make_directory_all(fmt.tprintf("%s/memory", state.settings.home_dir))
	// a custom subfolder (the Folders group's Reset and Reveal), an old main folder
	os.make_directory_all(fmt.tprintf("%s/memory-elsewhere-with-a-long-name", root))
	state.settings.folders[.Memory] = strings.clone(fmt.tprintf("%s/memory-elsewhere-with-a-long-name", root))
	state.home_dir_prev = strings.clone(fmt.tprintf("%s/memory", state.settings.home_dir))
	core.settings_gen += 1
	state.settings.jobs_paused = true
	mk :: proc(id, name, project: string) -> core.Job_Row {
		r := core.Job_Row{id = id, name = name, project = project, schedule = "0 7 * * 1-5", path = "/tmp/pd-audit-notes/jobs/x.md", enabled = true}
		return r
	}
	j1 := mk("a1", "Morning triage of every open pull request across all of my repositories", "pi-kit")
	j1.last_status, j1.last_headline, j1.unread, j1.last_run, j1.next_due = "ok", "3 PRs wait on you (oldest: pi-kit#9) and a very long headline that keeps on going", 2, "20261101T070000Z-1", core.jobs_now() + 3600
	append(&j1.recent, "- 2026-11-01 07:00 ✅ ok 1m12s $0.08 — 3 PRs wait on you (oldest: pi-kit#9) with more text · [run](file:///x/summary.md)", "- 2026-10-31 07:00 ⏭ skipped (asleep) ×3")
	append(&j1.needs_you, "blocked: bash `git push origin main --force-with-lease` in ~/workspace/pi-kit")
	j2 := mk("b2", "Heartbeat", "")
	append(&j2.warnings, "runs more often than every 30 minutes (cost)")
	j3 := mk("c3", "broken", "")
	j3.err = "frontmatter line 4: indented lines are not supported (flat key: value only)"
	j4 := mk("d4", "Paused one", "")
	j4.paused, j4.paused_why = true, "3 failures in a row"
	append(&state.jobs, j1, j2, j3, j4)
	state.jobs_unread = 2
	defer {
		clear(&state.jobs) // literals: not freed
		state.jobs_unread = 0
		state.settings.home_dir = saved_notes
		state.settings.folders = {}
		state.home_dir_prev = ""
		state.settings.jobs_paused = false
		jobs_ui_set("", false)
	}

	problems := 0
	report :: proc(t: ^testing.T, bad: []string, problems: ^int) {
		for b in bad {
			problems^ += 1
			if problems^ <= 400 do testing.expectf(t, false, "%v text: %s", state.settings.text_size, b)
		}
	}
	// every width at every text size; the looks, light and dark at the default size
	widths, sizes := AUDIT_WIDTHS, TEXT_SIZE_ORDER
	combo := 0 // the width/look/appearance combinations so far: this part takes every LAYOUT_PARTS-th
	for run in 0 ..< len(core.Text_Size) * len(widths) {
		w := widths[run % len(widths)]
		if size := sizes[run / len(widths)]; size != state.settings.text_size {
			state.settings.text_size = size
			fonts_apply(theme_font_config(theme()), 1)
		}
		for look in core.Theme_Id {
			for light in ([]bool{false, true}) {
				if state.settings.text_size != .Default && (look != .Graphite || light) do continue
				combo += 1
				if (combo - 1) % LAYOUT_PARTS != part do continue // another part's
				state.settings.theme = look
				state.settings.appearance = light ? .Light : .Dark
				for cols in 0 ..< 4 {
					state.layout.left_open = cols & 1 == 0
					state.layout.right_open = cols & 2 == 0
					for tab in core.Left_Tab {
						state.layout.left_tab = tab
						where_ := fmt.tprintf("w=%.0f %v %s left=%v right=%v %v", w, look, light ? "light" : "dark", state.layout.left_open, state.layout.right_open, tab)
						cmds := ui_layout(w, AUDIT_H)
						report(t, audit(cmds, where_, w)[:], &problems)
						if tab == .Jobs && state.layout.left_open {
							for open in ([]string{"a1", "b2"}) {
								jobs_ui_set(open, open == "b2")
								cmds = ui_layout(w, AUDIT_H)
								report(t, audit(cmds, fmt.tprintf("%s open %s", where_, open), w)[:], &problems)
							}
							jobs_ui_set("", false)
							menu_open(Menu_Job{id = "a1"}, {w - 40, 40})
							cmds = ui_layout(w, AUDIT_H)
							report(t, audit(cmds, fmt.tprintf("%s job menu", where_), w)[:], &problems)
							menu_close()
						}
					}
					// hovered rows (their buttons instead of the time) and open menus
					if state.layout.left_open {
						first_open := core.sidebar_open()[0].id
						for h in ([]Hit{Hit_Open_Row(first_open), Hit_Project(pl), Hit_Project(pa), Hit_Session("r2"), Hit_Chat("c1")}) {
							ui_hover = h
							cmds := ui_layout(w, AUDIT_H)
							report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d hover %v", w, look, light ? "light" : "dark", cols, h), w)[:], &problems)
						}
						ui_hover = nil
					}
					for target in ([]Menu_Target{Menu_New{}, Menu_Project(pl), Menu_Sort(.Projects)}) {
						menu_open(target, {w - 40, 40})
						cmds := ui_layout(w, AUDIT_H)
						report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d menu %v", w, look, light ? "light" : "dark", cols, target), w)[:], &problems)
						menu_close()
					}
					// the fleet (ui_fleet.odin): the pill hovered; no session on screen: the empty
					// centre's summary (r2 waits, g1 works), a row hovered
					{
						prev := state.current_session
						for hv in ([]Hit{Hit_Button(.Fleet), nil, Hit_Fleet_Row(open_session_of(pl, "g1"))}) {
							if hv == nil do state.current_session = 0
							ui_hover = hv
							cmds := ui_layout(w, AUDIT_H)
							report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d fleet hover %v session %d", w, look, light ? "light" : "dark", cols, hv, state.current_session), w)[:], &problems)
						}
						if !clay.GetElementData(clay.ID("fleetrow", 1)).found do testing.expectf(t, false, "w=%.0f cols=%d: the empty centre lists what runs", w, cols)
						if !clay.GetElementData(clay.ID("fleetpill")).found do testing.expectf(t, false, "w=%.0f cols=%d: the pill", w, cols)
						ui_hover = nil
						state.current_session = prev
					}
					// Atlas's drawer: its header (name, status, model, Model, 📌, ×), idle and working
					state.home_open = true
					state.settings.reduce_motion = true // in place, not sliding
					for working in ([]bool{false, true}) {
						if ht := core.home_tab(); ht != nil do ht.agent = working ? .Working : .Idle
						cmds := ui_layout(w, AUDIT_H)
						report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d drawer working=%v", w, look, light ? "light" : "dark", cols, working), w, "drawer_head", 5, {"drawer_model", "drawer_model_name", "drawer_pin", "drawer_close"})[:], &problems)
					}
					if ht := core.home_tab(); ht != nil do ht.agent = .Idle
					// sliding out, its terminal still shows (it has a rect); gone once out
					state.settings.reduce_motion = false
					state.home_open = false
					_ = ui_layout(w, AUDIT_H)
					_, _, _, _, sliding := drawer_term_rect()
					testing.expectf(t, sliding, "w=%.0f: the terminal shows while the drawer slides out", w)
					state.settings.reduce_motion = true
					_ = ui_layout(w, AUDIT_H) // slid out at once
					_, _, _, _, out := drawer_term_rect()
					testing.expectf(t, !out, "w=%.0f: no terminal once the drawer is out", w)
					state.settings.reduce_motion = false
					// the Files tab's checkout switcher open (rows hovered), and a worktree's actions
					if state.layout.left_open {
						state.layout.left_tab = .Files
						_ = ui_layout(w, AUDIT_H) // the menu anchors to the switcher's last box
						wt_menu_toggle()
						for hv in ([]Hit{nil, Hit_Files{what = .Switcher}, Hit_Files{what = .Wt_Row, index = 1}, Hit_Files{what = .Wt_More, index = 0}, Hit_Files{what = .Wt_Row, index = 5}}) {
							ui_hover = hv
							cmds := ui_layout(w, AUDIT_H)
							report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d switcher hover %v", w, look, light ? "light" : "dark", cols, hv), w)[:], &problems)
						}
						ui_hover = nil
						if !clay.GetElementData(clay.ID("wtrow", 5)).found do testing.expect(t, false, "the switcher's menu lists the branches")
						wt_menu_close()
						menu_open(Menu_Worktree{path = alpha, branch = "main"}, {40, 160})
						cmds := ui_layout(w, AUDIT_H)
						report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d worktree menu", w, look, light ? "light" : "dark", cols), w)[:], &problems)
						menu_close()
					}
					// the Changes tab: header, commit row, notice, list, file bar, Show more; hovered
					if cs := core.find_session(ch_session); cs != nil && ch_tab != 0 {
						prev := state.current_session
						state.current_session = cs.id
						cs.active_tab = ch_tab
						for hv in ([]Hit{nil, Hit_Changes{what = .Row, index = 2}, Hit_Changes{what = .Tool, index = int(Changes_Tool.Stage)}, Hit_Changes{what = .Tool, index = int(Changes_Tool.Merge)}, Hit_Changes{what = .Button}}) {
							ui_hover = hv
							_ = ui_layout(w, AUDIT_H) // the list's height
							cmds := ui_layout(w, AUDIT_H)
							report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d changes hover %v", w, look, light ? "light" : "dark", cols, hv), w)[:], &problems)
						}
						state.focus_widget = "changes_message"
						cmds := ui_layout(w, AUDIT_H)
						report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d changes message", w, look, light ? "light" : "dark", cols), w)[:], &problems)
						state.focus_widget = ""
						ui_hover = nil
						state.current_session = prev
					}
					// the Markdown tab's toolbar: preview and source
					if cs := core.find_session(ch_session); cs != nil && md_tab != 0 {
						prev := state.current_session
						state.current_session = cs.id
						cs.active_tab = md_tab
						for source in ([]bool{false, true}) {
							core.run_command(core.Markdown_Set_View{tab_id = md_tab, source = source}, {kind = .UI})
							cmds := ui_layout(w, AUDIT_H)
							report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d markdown source=%v", w, look, light ? "light" : "dark", cols, source), w)[:], &problems)
						}
						core.run_command(core.Markdown_Set_View{tab_id = md_tab, source = false}, {kind = .UI})
						state.current_session = prev
					}
					// the settings popover over it all
					state.layout.left_tab = .Sessions
					state.focus_widget = "settings"
					_ = ui_layout(w, AUDIT_H) // the popover anchors to the button's last box
					cmds := ui_layout(w, AUDIT_H)
					report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d settings", w, look, light ? "light" : "dark", cols), w)[:], &problems)
					state.focus_widget = ""
					// the first-run sheet (ui_setup.odin): every step, a long found
					// path, a picked folder, a separate chats folder, hovered
					if cols == 0 {
						setup_begin()
						delete(setup_ui.detected)
						setup_ui.detected = strings.clone("/Users/someone/Documents/notes/agents-with-a-rather-long-folder-name/and-deeper")
						delete(setup_ui.why)
						setup_ui.why = strings.clone("named in ~/.pi/agent/AGENTS.md; it has a sessions/ folder")
						state.focus_widget = "setup"
						// the accounts step: found ones, one typed in without Claude Code's files, a long label, a warning
						for d, k in ([]string{"/Users/someone/.claude", "/Users/someone/.claude-work", "/Volumes/External/a-very-long-folder-name-for-claude/config-of-the-team"}) {
							append(&setup_ui.accounts, core.Setup_Account{dir = strings.clone(d), label = strings.clone(k == 2 ? "A rather long account name for here" : core.claude_account_label_of(d)), orig_label = strings.clone(""), keep = k != 1, fixed = k == 0, hand = k == 2, marked = k != 2})
						}
						setup_ui.acct_show = true
						setup_ui.acct_default = 2
						delete(setup_ui.acct_msg)
						setup_ui.acct_msg = strings.clone("It has no Claude Code files yet (.claude.json, .credentials.json): added anyway; Claude Code makes them when you sign in there.")
						for step in 0 ..< setup_steps() {
							setup_ui.step = step
							for variant in 0 ..< 2 {
								setup_ui.main = variant == 0 ? .Detected : .Other
								delete(setup_ui.other)
								setup_ui.other = strings.clone(variant == 0 ? "" : "/Volumes/External/a-very-long-folder-name-for-all-of-my-notes-and-more")
								setup_ui.separate = variant == 1
								for hv in ([]Hit{nil, Hit_Setup{what = .Option, index = 1}, Hit_Setup{what = .Next}}) {
									ui_hover = hv
									cmds = ui_layout(w, AUDIT_H)
									report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s setup step %d variant %d hover %v", w, look, light ? "light" : "dark", step + 1, variant, hv), w)[:], &problems)
									if !clay.GetElementData(clay.ID("setupbtn", u32(Setup_Hit_Kind.Next))).found do testing.expectf(t, false, "w=%.0f: the sheet has its Next/Done", w)
								}
							}
						}
						ui_hover = nil
						state.focus_widget = ""
						setup_ui.acct_show = false
					}
					// the bell's popover over it all, a row hovered
					state.focus_widget = "notifications"
					_ = ui_layout(w, AUDIT_H) // anchors to the bell's last box
					for hv in ([]Hit{nil, Hit_Bell{what = .Row, id = state.notices.items[2].id}, Hit_Bell{what = .Mark_All}}) {
						ui_hover = hv
						cmds = ui_layout(w, AUDIT_H)
						report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d bell hover %v", w, look, light ? "light" : "dark", cols, hv), w)[:], &problems)
						if !clay.GetElementData(clay.ID("bellrow", 6)).found do testing.expectf(t, false, "w=%.0f: the bell lists its entries", w)
					}
					ui_hover = nil
					state.focus_widget = ""
					// the Settings tab, its folders open, a row hovered (its "…"), a missing file's Create
					if state.layout.left_open {
						state.layout.left_tab = .Settings
						cmds = ui_layout(w, AUDIT_H)
						for slot in 0 ..< 48 {
							ui_hover = Hit_Files{what = .Row, index = slot}
							cmds = ui_layout(w, AUDIT_H)
							report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d settings hover %d", w, look, light ? "light" : "dark", cols, slot), w)[:], &problems)
						}
						// the Folders group's buttons, hovered (folders.odin)
						for slot in 0 ..< 48 do for what in ([]Files_Hit_Kind{.Folder_Reset, .Folder_Reveal}) {
							if state.settings.text_size != .Default do break
							ui_hover = Hit_Files{what = what, index = slot}
							cmds = ui_layout(w, AUDIT_H)
							report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d settings %v %d", w, look, light ? "light" : "dark", cols, what, slot), w)[:], &problems)
						}
						if !clay.GetElementData(clay.ID("freset", 0)).found {
							found := false
							for i in u32(0) ..< 64 do if clay.GetElementData(clay.ID("freset", i)).found do found = true
							testing.expectf(t, found, "w=%.0f: a custom folder has its Reset", w)
						}
						ui_hover = Hit_Files{what = .Create, index = 9}
						cmds = ui_layout(w, AUDIT_H)
						report(t, audit(cmds, fmt.tprintf("w=%.0f %v %s cols=%d settings create", w, look, light ? "light" : "dark", cols), w)[:], &problems)
						ui_hover = nil
						state.layout.left_tab = .Sessions
					}
				}
			}
		}
	}
	state.settings.text_size = .Default
	fonts_apply(theme_font_config(theme()), 1)
	testing.expectf(t, problems == 0, "%d layout problems", problems)
	state.layout.left_open, state.layout.right_open = true, true
	core.close_all()
}

// Fonts and Clay once, at 1x, without a window (layout only, no drawing).
audit_ui :: proc() -> bool {
	@(static) ready: bool
	if ready do return true
	core.app_context = context // text measuring (Clay's callback) runs in it
	app.dpi = 1
	font.size = ATLAS_MIN
	font.pixels = make([]u8, ATLAS_MIN * ATLAS_MIN * 4)
	if !fonts_apply(theme_font_config(theme()), 1) do return false
	if ui_memory == nil do ui_init()
	ready = true
	return true
}


// Rename (palette, menu) always has a field to type into: also while
// Projects is folded or the filter leaves the selected project out.
@(test)
rename_field_always_shows :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/pd-rename-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	os.make_directory_all(root)
	context.allocator = au_reset("")
	if !testing.expect(t, audit_ui(), "fonts") do return
	r := core.run_command(core.Add_Project{cwd = root}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	shown :: proc() -> bool {
		_ = ui_layout(1400, AUDIT_H)
		return clay.GetElementData(clay.ID("rename_field")).found
	}
	state.focus_widget = "rename_project"
	testing.expect(t, shown(), "the row's field")
	state.sidebar.folded[.Projects] = true
	testing.expect(t, shown(), "Projects folded")
	state.sidebar.folded[.Projects] = false
	core.run_command(core.Set_Filter{text = "zzzz"}, {kind = .UI})
	testing.expect(t, shown(), "filtered out")
	core.run_command(core.Set_Filter{text = ""}, {kind = .UI})
	state.focus_widget = ""
}

// Every construct, long words, wide tables, deep lists, long code lines.
MD_AUDIT_DOC :: "# A heading long enough to wrap across more than one line at the narrowest widths we lay out\n\n" +
	"Body text with *emphasis*, **strong**, ~~struck~~, `code spans`, a [link](https://example.com), an autolink www.example.com and an ![image of a bowl of soup](soup.png). " +
	"A very long word: Averyveryverylongwordwithoutanyspacesthatmustbecutbetweencharacters. Glued runs: a built-in assistant, **Atlas**, in a drawer; [x](#y), `z`; (**bold**).\n\n" +
	"- [ ] an open task\n- [x] a done task\n  1. nested ordered with a long line of text that wraps at narrow widths and keeps going\n  2. second\n     - deeper\n       - deeper still with `code`\n\n" +
	"> A quote with a [link inside](#a-heading) and enough text to wrap onto a second line at most widths.\n>\n> > A nested quote.\n\n" +
	"| Name | Minutes | A long header for a column that has long notes | Right |\n|:-----|:-:|---|--:|\n| Soup | 30 | *hot*, with a long note that wraps inside its cell at narrow widths | 1 |\n| Salad | 5 | `cold` | 22 |\n| Averyveryverylongcellwithoutspaces | 1 | x | 333 |\n\n" +
	"```go\nfunc main() {\n\tfmt.Println(\"a long line of code that goes on and on past the right edge of the pane at narrow widths\")\n}\n```\n\n" +
	"```mermaid\ngraph TD\n  A --> B\n```\n\n    indented code\n\n<div>an html block</div>\n\n---\n\n###### A small heading\n\nThe end.\n"

MD_GUIDE :: #load("../docs/GUIDE.md", string)

// The preview's own layout (drawn by md_draw, not Clay): at pane widths from
// narrow to wide, every text size and 1x/2x, no text overlaps other text, all
// of it stays inside the pane, each piece is as wide as its shaped run (words
// measured one by one add up to more at 2x), and punctuation glued to a styled
// run never starts a line on its own.
@(test)
markdown_preview_audit :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	saved_size := state.settings.text_size
	defer {
		state.settings.text_size = saved_size
		app.dpi = 1
		fonts_apply(theme_font_config(theme()), 1)
	}
	problems := 0
	bad :: proc(t: ^testing.T, problems: ^int, format: string, args: ..any) {
		problems^ += 1
		if problems^ <= 60 do testing.expectf(t, false, format, ..args)
	}
	for text in ([]string{MD_AUDIT_DOC, MD_GUIDE}) {
		v := new(Md_View)
		v.doc = md_parse(text)
		defer {
			md_free(v.doc)
			lay_free(&v.lay)
			free(v)
		}
		for size in core.Text_Size do for dpi in ([]f32{1, 2}) {
			state.settings.text_size = size
			app.dpi = dpi
			fonts_apply(theme_font_config(theme()), dpi)
			for pane in ([]f32{320, 480, 700, 1000, 1400}) {
				w := pane * dpi
				md_layout(v, w)
				where_ := fmt.tprintf("%v %vx pane=%v", size, dpi, pane)
				ps := v.lay.pieces[:]
				line_x0: map[f32]f32 // each line's leftmost text
				defer delete(line_x0)
				for p in ps do if p.kind == .Text {
					if p.x < -0.5 || p.x + p.w > w + 0.5 do bad(t, &problems, "%s: %q outside the pane (x %.1f..%.1f of %.1f)", where_, p.text, p.x, p.x + p.w, w)
					if !(p.font == .Mono && p.scale == 1 && !p.code) {
						real := md_measure(p.text, {font = p.font, bold = p.bold, italic = p.italic, scale = p.scale})
						if abs(real - p.w) > 0.5 && p.find >= 0 do bad(t, &problems, "%s: %q is %.1f wide, its run %.1f", where_, p.text, p.w, real)
					}
					if x, ok := line_x0[p.y]; !ok || p.x < x do line_x0[p.y] = p.x
				}
				for p, i in ps do if p.kind == .Text && p.find >= 0 && !p.code && p.font != .Mono && len(p.text) > 0 && strings.index_byte(",.;)", p.text[0]) >= 0 {
					if line_x0[p.y] != p.x || p.x <= 0 do continue
					// unavoidable only when the run before it already starts its line (a narrow table column)
					k := i - 1
					for k >= 0 && (ps[k].kind != .Text || ps[k].y >= p.y) do k -= 1
					if k >= 0 && line_x0[ps[k].y] == ps[k].x do continue
					bad(t, &problems, "%s: a line starts with %q (after %q)", where_, p.text, k >= 0 ? ps[k].text : "")
				}
				// overlap: pieces sorted by y; compare each with the following ones on overlapping lines
				for a, i in ps do if a.kind == .Text {
					for j := i + 1; j < len(ps) && ps[j].y < a.y + a.h - 0.5; j += 1 {
						b := ps[j]
						if b.kind != .Text do continue
						if b.x < a.x + a.w - 0.5 && a.x < b.x + b.w - 0.5 && b.y < a.y + a.h - 0.5 && a.y < b.y + b.h - 0.5 {
							bad(t, &problems, "%s: %q overlaps %q", where_, a.text, b.text)
						}
					}
				}
			}
		}
	}
}

// Layout of inputs that are slow for a naive line breaker: a long word, a
// long inline code span, a long URL and long link text. 16 KB versions first
// (a quadratic layout shows there, in tenths of a second and a few hundred
// MB); only if they are fast, the 200 KB versions (quadratic: minutes and
// tens of GB, so never run them on a layout that failed the small ones).
@(test)
markdown_layout_pathological :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	rep :: proc(s: string, n: int) -> string {return strings.repeat(s, n, context.temp_allocator)}
	cases :: proc(k: int) -> [4][2]string {
		return {
			{"a word", rep("abcdefghij", k)},
			{"a code span", strings.concatenate({"`", rep("x=1;", k * 10 / 4), "`"}, context.temp_allocator)},
			{"a URL", strings.concatenate({"https://example.com/", rep("a1b2c3d4e5", k)}, context.temp_allocator)},
			{"link text", strings.concatenate({"[", rep("q", k * 10), "](x.md)"}, context.temp_allocator)},
		}
	}
	run :: proc(t: ^testing.T, name, text: string, limit: time.Duration) -> (gate_ok, budget_ok: bool) {
		v := new(Md_View)
		v.doc = md_parse(text)
		t0 := core.thread_cpu_now() // CPU time: a busy machine does not fail it
		for w in ([]f32{700, 1300}) do md_layout(v, w)
		d := core.thread_cpu_since(t0)
		fmt.printfln("markdown layout: %s (%d KB) in %.1f ms", name, len(text) / 1000, f64(d) / f64(time.Millisecond))
		md_free(v.doc)
		lay_free(&v.lay)
		free(v)
		free_all(context.temp_allocator)
		gate_ok = core.perf_expect(t, fmt.tprintf("markdown layout: %s (%d KB)", name, len(text) / 1000), d, limit)
		return gate_ok, d <= limit
	}
	small_gate, small_budget := true, true
	for c in cases(1_600) {
		g, b := run(t, c[0], c[1], 50 * time.Millisecond)
		small_gate &= g
		small_budget &= b
	}
	if !small_gate do return // failed: not linear, and the 200 KB cases would take minutes and tens of GB
	big := cases(20_000)
	n := len(big)
	if !small_budget {
		// over the budget but within the gate (a busy machine, most likely): one 200 KB case still
		// runs, so the large size is never silently left out
		fmt.printfln("PERF OVER BUDGET markdown layout: a 16 KB case was over budget: only one 200 KB case runs")
		n = 1
	}
	for c in big[:n] do run(t, c[0], c[1], time.Second)
	for c in cases(20_000) do run(t, c[0], c[1], time.Second)
}

// An HTML block whose '<'s never close (each scanned to the end: quadratic).
@(test)
markdown_html_pathological :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	v := new(Md_View)
	v.doc = md_parse(strings.concatenate({"<div>\n", strings.repeat("<a ", 350_000, context.temp_allocator), "\n"}, context.temp_allocator))
	t0 := core.thread_cpu_now() // CPU time: a busy machine does not fail it
	md_layout(v, 700)
	d := core.thread_cpu_since(t0)
	fmt.printfln("markdown layout: an unclosed '<' in HTML, 1 MB, in %.1f ms", f64(d) / f64(time.Millisecond))
	core.perf_expect(t, "markdown_html_pathological: an unclosed '<' in HTML, 1 MB", d, time.Second)
	md_free(v.doc)
	lay_free(&v.lay)
	free(v)
}

// The confirmation bar keeps Cancel and Confirm inside the window however long
// its summary is: the summary wraps (at most CONFIRM_LINES lines, the last cut
// with an ellipsis) and the bar grows to hold it, at the narrowest window, with
// the left column open or closed; a short summary keeps the one-line bar.
@(test)
confirm_bar_keeps_its_buttons :: proc(t: ^testing.T) {
	context.allocator = au_reset("")
	if !testing.expect(t, audit_ui(), "fonts") do return
	defer clear(&state.pending_confirmations)
	long := "Reload 3 pi tabs? Background work that a reload would stop: ~/code/garden-planner-with-a-rather-long-folder-name-that-keeps-going (shell sh1: npm test -- --watch --coverage --reporter=verbose; shell sh2: cargo build --release; +4). Those tabs wait until it ends, then reload on their own. " +
		"Unsaved comments stay where they are and go with the next message typed into each pi tab, so nothing is lost by reloading now rather than later on."
	path := fmt.tprintf("Delete %s?", strings.repeat("/averyveryverylongfoldernamewithoutanyspaces", 12, context.temp_allocator))
	for summary in ([]string{"Close this session?", long, path}) {
		clear(&state.pending_confirmations)
		append(&state.pending_confirmations, core.Pending_Confirmation{token = "tok", summary = summary, command = core.Quit{}, class = .App_Quit, caller = {kind = .UI}})
		for left_open in ([]bool{true, false}) {
			state.layout.left_open = left_open
			for w in ([]f32{WINDOW_MIN_W, 1280}) {
				cmds := ui_layout(w, AUDIT_H)
				bar := clay.GetElementData(clay.ID("confirm_bar"))
				if !testing.expectf(t, bar.found, "%v: no confirm_bar", w) do continue
				bb := box_of(bar.boundingBox)
				win := Box{0, 0, w, AUDIT_H}
				for name in ([]string{"confirm_no", "confirm_yes"}) {
					d := clay.GetElementData(clay.ID(name))
					b := box_of(d.boundingBox)
					testing.expectf(t, d.found && inside_box(b, win) && inside_box(b, bb), "w=%v left=%v %q: %s at %v, bar %v", w, left_open, summary[:12], name, b, bb)
				}
				// the summary's text: inside the bar, clear of the buttons, at most CONFIRM_LINES lines
				cancel := box_of(clay.GetElementData(clay.ID("confirm_no")).boundingBox)
				lines := 0
				text := ""
				for p in pieces(cmds) {
					mid := (p.box.y0 + p.box.y1) / 2
					if p.text == "" || p.text == "Cancel" || p.text == "Confirm" || mid < bb.y0 || mid > bb.y1 do continue
					if p.box.x1 <= bb.x0 + 0.5 do continue // the sidebar's own text beside the bar
					testing.expectf(t, inside_box(p.box, bb) && p.box.x1 <= cancel.x0 + 0.5, "w=%v left=%v: text %q at %v outside the bar %v or under Cancel %v", w, left_open, p.text, p.box, bb, cancel)
					lines += 1
					text = p.text
				}
				testing.expectf(t, lines >= 1 && lines <= CONFIRM_LINES, "w=%v left=%v: %d lines", w, left_open, lines)
				if summary == long && w == WINDOW_MIN_W do testing.expectf(t, strings.has_suffix(text, "…"), "cut with an ellipsis: %q", text)
				if summary == "Close this session?" do testing.expectf(t, abs(bar.boundingBox.height - px(BAR_H)) < 0.5, "short: one-line bar, got %v", bar.boundingBox.height)
			}
		}
	}
	state.layout.left_open = true
}

// The gear's popover in a short window: it stays inside the window and its rows scroll, the
// keyboard's row kept in view; its groups have headers.
@(test)
settings_popover_short_window :: proc(t: ^testing.T) {
	context.allocator = au_reset("")
	if !testing.expect(t, audit_ui(), "fonts") do return
	W, H :: 1280, 600
	state.focus_widget = "settings"
	defer state.focus_widget = ""
	_ = ui_layout(W, H) // anchors to the gear's last box
	_ = ui_layout(W, H)
	pop := clay.GetElementData(clay.ID("settings_pop"))
	list := clay.GetElementData(clay.ID("settings_list"))
	if !testing.expect(t, pop.found && list.found, "the popover and its list") do return
	testing.expectf(t, inside_box(box_of(pop.boundingBox), Box{0, 0, W, H}), "the popover %v leaves the %vx%v window", pop.boundingBox, W, H)
	for g in 0 ..< len(POP_GROUPS) do testing.expectf(t, clay.GetElementData(clay.ID("pop_head", u32(g))).found, "group header %d", g)
	// the last row, picked with the keyboard, scrolls into the list's view
	popover.selected = int(Pop_Item.Control_Token)
	_ = ui_layout(W, H)
	_ = ui_layout(W, H)
	row := clay.GetElementData(clay.ID("pop", u32(Pop_Item.Control_Token)))
	list = clay.GetElementData(clay.ID("settings_list"))
	testing.expectf(t, row.found && inside_box(box_of(row.boundingBox), box_of(list.boundingBox)), "the selected last row %v shows in the list %v", row.boundingBox, list.boundingBox)
}

// The gear's Notifications grid at every text size: its header and four rows say what they
// should (the defaults), its columns line up, every cell fits the popover and its row, and a
// changed choice is drawn.
@(test)
settings_bell_grid :: proc(t: ^testing.T) {
	context.allocator = au_reset("")
	if !testing.expect(t, audit_ui(), "fonts") do return
	W, H :: 1280, 860
	state.focus_widget = "settings"
	defer {
		state.focus_widget = ""
		state.settings.text_size = .Default
		fonts_apply(theme_font_config(theme()), 1)
	}
	texts_in :: proc(cmds: clay.ClayArray(clay.RenderCommand), id: clay.ElementId) -> string {
		d := clay.GetElementData(id)
		if !d.found do return "<none>"
		b := box_of(d.boundingBox)
		out := make([dynamic]string, context.temp_allocator)
		for p in pieces(cmds) do if p.text != "" && inside_box(p.box, b) do append(&out, p.text)
		return strings.join(out[:], " ", context.temp_allocator)
	}
	for size in core.Text_Size {
		state.settings.text_size = size
		fonts_apply(theme_font_config(theme()), 1)
		_ = ui_layout(W, H)
		cmds := ui_layout(W, H)
		testing.expect_value(t, texts_in(cmds, clay.ID("bell_grid_head")), "Notify me about Bell macOS Sound")
		want := [4]string{"Needs you background Tink", "Finished never none", "Errors background none", "Jobs background none"}
		for g, i in BELL_GRID_ORDER do testing.expectf(t, texts_in(cmds, clay.ID("bell_grid_row", u32(g))) == want[i], "%v row %v: %q", size, g, texts_in(cmds, clay.ID("bell_grid_row", u32(g))))
		pop := box_of(clay.GetElementData(clay.ID("settings_pop")).boundingBox)
		x0: [3]f32
		for g, i in BELL_GRID_ORDER {
			row := box_of(clay.GetElementData(clay.ID("bell_grid_row", u32(g))).boundingBox)
			cells := [3]Pop_Item{Pop_Item(int(Pop_Item.Bell_Finished) + int(g)), Pop_Item(int(Pop_Item.Os_Finished) + int(g)), Pop_Item(int(Pop_Item.Sound_Finished) + int(g))}
			for it, c in cells {
				d := clay.GetElementData(clay.ID("pop", u32(it)))
				if !testing.expectf(t, d.found, "%v cell %v", size, it) do continue
				b := box_of(d.boundingBox)
				testing.expectf(t, inside_box(b, row) && inside_box(b, pop), "%v: %v %v leaves its row %v", size, it, b, row)
				if i == 0 do x0[c] = b.x0
				else do testing.expectf(t, abs(b.x0 - x0[c]) < 0.5, "%v: column %d not aligned (%v vs %v)", size, c, b.x0, x0[c])
			}
		}
		report_bad := audit(cmds, fmt.tprintf("bell grid %v", size), W)
		for b in report_bad do testing.expect(t, false, b)
	}
	// a changed choice shows (the replica is the State here)
	state.settings.text_size = .Default
	fonts_apply(theme_font_config(theme()), 1)
	core.run_command(core.Set_Bell{macos = #partial [core.Bell_Group]Maybe(core.Os_When){.Jobs = .Always}, sound = #partial [core.Bell_Group]Maybe(core.Bell_Sound){.Jobs = .Basso}, jobs = false}, {kind = .UI})
	_ = ui_layout(W, H)
	cmds := ui_layout(W, H)
	testing.expect_value(t, texts_in(cmds, clay.ID("bell_grid_row", u32(core.Bell_Group.Jobs))), "Jobs always Basso")
	// the keyboard walks the grid row by row after Agent notifications
	order := POP_ORDER
	at := -1
	for o, k in order do if o == .Notifications do at = k
	testing.expect(t, at >= 0 && order[at + 1] == .Bell_Waiting && order[at + 2] == .Os_Waiting && order[at + 3] == .Sound_Waiting && order[at + 4] == .Bell_Finished, "grid order")
	testing.expect(t, !pop_item_shown(.Bell_OS), "the old switch is not drawn")
	label, _ := hit_tip(Hit_Pop(Pop_Item.Sound_Waiting))
	testing.expectf(t, strings.contains(label, "background") && strings.contains(label, "always"), "the rule in the tip: %q", label)
}

// An error toast wraps to two lines inside its box; an info toast stays one line.
@(test)
toast_error_wraps :: proc(t: ^testing.T) {
	context.allocator = au_reset("")
	if !testing.expect(t, audit_ui(), "fonts") do return
	defer toast_clear()
	long := "No coding agent is installed on that machine: Settings › Machines lists what it needs, and a little more so it is surely longer than one line of the toast"
	for err in ([]bool{true, false}) {
		toast_show(long, err)
		cmds := ui_layout(WINDOW_MIN_W, AUDIT_H)
		d := clay.GetElementData(clay.ID("toast"))
		if !testing.expect(t, d.found, "the toast") do continue
		box := box_of(d.boundingBox)
		lines := 0
		for p in pieces(cmds) do if p.z == 29 && p.text != "" {
			lines += 1
			testing.expectf(t, inside_box(p.box, box), "err=%v: %q outside the toast %v", err, p.text, box)
		}
		testing.expectf(t, lines == (err ? 2 : 1), "err=%v: %d lines", err, lines)
		testing.expect(t, inside_box(box, Box{0, 0, WINDOW_MIN_W, AUDIT_H}), "the toast is inside the window")
	}
}

// The editor's changed-on-disk banner keeps its buttons inside the window
// for a long file name (its message is cut with an ellipsis).
@(test)
disk_banner_keeps_its_buttons :: proc(t: ^testing.T) {
	root := fmt.tprintf("%s/pd-banner-%d", os.get_env("TMPDIR", context.temp_allocator), time.now()._nsec)
	os.make_directory_all(root)
	context.allocator = au_reset("")
	if !testing.expect(t, audit_ui(), "fonts") do return
	ui := core.Caller{kind = .UI}
	core.run_command(core.Add_Project{cwd = root}, ui)
	core.run_command(core.New_Chat{project_id = state.selected_project}, ui)
	file := fmt.tprintf("%s/%s.txt", root, strings.repeat("a-file-with-a-long-name-", 8, context.temp_allocator))
	_ = os.write_entire_file(file, transmute([]u8)string("hello\n"))
	r := core.run_command(core.Open_File{path = file}, ui)
	if !testing.expect(t, r.ok, r.error) do return
	e := tab_editor()
	if !testing.expect(t, e != nil, "an editor tab") do return
	e.disk_changed = true
	defer e.disk_changed = false
	for w in ([]f32{WINDOW_MIN_W, 1280}) {
		_ = ui_layout(w, AUDIT_H)
		banner := clay.GetElementData(clay.ID("ed_banner"))
		if !testing.expect(t, banner.found, "the banner") do continue
		bb := box_of(banner.boundingBox)
		for name in ([]string{"ed_compare", "ed_keep", "ed_reload"}) {
			b := box_of(clay.GetElementData(clay.ID(name)).boundingBox)
			testing.expectf(t, inside_box(b, Box{0, 0, w, AUDIT_H}) && inside_box(b, bb), "w=%v: %s at %v, banner %v", w, name, b, bb)
		}
	}
	if cs := core.cur(); cs != nil do core.run_command(core.Close_Session{session = cs.id}, ui)
	for p in state.pending_confirmations do core.run_command(core.Cancel_Confirmation{token = p.token}, ui)
}
