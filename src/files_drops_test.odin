package main

// Drops across the Files tree's edges (ui_files_drops.odin), through event() on a laid-out
// window: a tree drag released over pane B delivers to B only, never to the focused pane A (a
// terminal: the quoted paths; Claude Code's prompt: the plain paths; an editor: the file opens
// there); over nothing, nothing. Files dropped from Finder (sidebar_drop, FILES_DROPPED's own
// entry point) onto the tree's list are copied into the folder under the drop; elsewhere in the
// left column folders still become projects. A Finder drag's hover shows the target's band.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
FX_W :: 1400
@(private = "file")
FX_H :: 860

// Every send_text run, as "tab:text".
@(private = "file")
fx_sent: [dynamic]string

@(private = "file")
fx_setup :: proc(tag: string) -> string {
	context.allocator = runtime.heap_allocator()
	pk_reset()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/deckhand-fdrops-%s-%d", strings.trim_right(tmp, "/"), tag, time.now()._nsec)
	os.make_directory_all(made)
	dir := core.fs_real(made, context.allocator)
	ensure(strings.contains(dir, "/deckhand-fdrops-") && os.is_directory(dir), "files drops tests: no temp folder")
	state.projects[0].cwd = dir
	pk_session(100, "Here", pk_tab(101), pk_tab(102))
	state.open_sessions[0].cwd = strings.clone(dir)
	state.current_session = 100
	_ = pk_view(101, 80, 24)
	_ = pk_view(102, 80, 24)
	state.layout.left_tab = .Files
	core.files_refresh()
	core.files_state_gen += 1
	clear(&fx_sent)
	core.after_command_check = proc(cmd: core.Command) {
		if st, is := cmd.(core.Send_Text); is do append(&fx_sent, fmt.aprintf("%d:%s", st.tab_id, st.text, allocator = runtime.heap_allocator()))
	}
	return dir
}

@(private = "file")
fx_write :: proc(dir, name: string) -> string {
	p, _ := filepath.join({dir, name})
	os.make_directory_all(filepath.dir(p))
	_ = os.write_entire_file(p, transmute([]u8)string("x"))
	core.files_path_changed(p)
	return p
}

@(private = "file")
fx_lay :: proc() {
	_ = ui_layout(FX_W, FX_H)
	ui_pane_rects(core.cur()) // as a frame does (main.odin)
}

@(private = "file")
fx_row :: proc(suffix: string) -> (x, y: f32, ok: bool) {
	fx_lay()
	slot := files_drawn_slot(suffix)
	if slot < 0 do return
	d := clay.GetElementData(clay.ID("frow", u32(slot)))
	if !d.found do return
	b := d.boundingBox
	return b.x + b.width / 2 - 30, b.y + b.height / 2, true
}

@(private = "file")
fx_ev :: proc(type: sapp.Event_Type, x, y: f32, mods: u32 = 0) {
	e := sapp.Event{type = type, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = mods}
	event(&e)
	core.inbox_drain()
}

// A drag of the row at (fx, fy) to (tx, ty), released there.
@(private = "file")
fx_drag :: proc(fx, fy, tx, ty: f32) {
	app.last_click = {} // a fresh press, never the second of a double-click (an earlier test's press at the same row)
	fx_ev(.MOUSE_DOWN, fx, fy)
	fx_lay()
	fx_ev(.MOUSE_MOVE, fx, fy + 12, sapp.MODIFIER_LMB)
	fx_lay()
	fx_ev(.MOUSE_MOVE, tx, ty, sapp.MODIFIER_LMB)
	fx_lay()
	fx_ev(.MOUSE_UP, tx, ty)
}

// Two panes side by side: A (tab 101, focused) and B (tab 102). Their frames' centres.
@(private = "file")
fx_split :: proc() -> (a, b: [2]f32, a_id, b_id: u64) {
	r := core.run_command(core.Split_Pane{direction = .Right, tab_id = 102, no_focus = true}, {kind = .UI})
	ensure(r.ok, r.error)
	s := core.cur()
	pa, pb := core.pane_of_tab(s, 101), core.pane_of_tab(s, 102)
	core.run_command(core.Focus_Pane{pane = pa.id}, {kind = .UI})
	fx_lay()
	fx_lay()
	s = core.cur()
	pa, pb = core.pane_of_tab(s, 101), core.pane_of_tab(s, 102)
	ra, rb := pa.frame, pb.frame
	return {ra.x + ra.z / 2, ra.y + ra.w / 2}, {rb.x + rb.z / 2, rb.y + rb.w / 2}, pa.id, pb.id
}

@(test)
files_drop_onto_the_pane_under_the_pointer :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	defer pk_reset()
	defer core.after_command_check = nil
	dir := fx_setup("panes")
	defer os.remove_all(dir)
	ap := fx_write(dir, "a.txt")
	fx_write(dir, "b c.md")
	a, b, a_id, b_id := fx_split()
	testing.expect(t, a_id != b_id && core.session_focused_pane(core.cur()).id == a_id, "A is focused")
	testing.expect_value(t, files_pane_target(b.x, b.y).pane, b_id)
	testing.expect_value(t, files_pane_target(b.x, b.y).action, core.Pane_Drop.Paste_Path)

	// a terminal in B: the quoted path into B only, nothing into A (the focused one)
	x, y, ok := fx_row("/a.txt")
	if !testing.expect(t, ok, "row drawn") do return
	fx_drag(x, y, b.x, b.y)
	testing.expectf(t, len(fx_sent) == 1 && fx_sent[0] == fmt.tprintf("102:'%s' ", ap), "sent %v", fx_sent[:])
	testing.expect_value(t, pk_take(101), "")
	testing.expect_value(t, core.session_focused_pane(core.cur()).id, a_id)

	// while dragging over B: B ringed, the ghost says what happens
	clear(&fx_sent)
	x, y, _ = fx_row("/a.txt")
	fx_ev(.MOUSE_DOWN, x, y)
	fx_lay()
	fx_ev(.MOUSE_MOVE, x, y + 12, sapp.MODIFIER_LMB)
	fx_lay()
	fx_ev(.MOUSE_MOVE, b.x, b.y, sapp.MODIFIER_LMB)
	fx_lay()
	ring := clay.GetElementData(clay.ID("files_pane_drop"))
	testing.expect(t, ring.found && ring.boundingBox.x > a.x, "B is ringed")
	testing.expect_value(t, files_pane_drop_label(), "Paste path")
	// Esc cancels: nothing anywhere
	esc := sapp.Event{type = .KEY_DOWN, key_code = .ESCAPE}
	event(&esc)
	fx_ev(.MOUSE_UP, b.x, b.y)
	testing.expectf(t, len(fx_sent) == 0, "Esc: sent %v", fx_sent[:])

	// Claude Code in B: the plain paths into its prompt (a space after each; never Enter)
	s := core.cur()
	for &tab in s.tabs do if tab.id == 102 do tab.kind = core.Claude_Tab{harness = .Claude}
	testing.expect_value(t, files_pane_target(b.x, b.y).action, core.Pane_Drop.Insert_Prompt)
	x, y, _ = fx_row("/b c.md")
	fx_drag(x, y, b.x, b.y)
	testing.expectf(t, len(fx_sent) == 1 && fx_sent[0] == fmt.tprintf("102:'%s/b c.md' ", dir), "sent %v", fx_sent[:])
	testing.expect(t, !strings.contains(fx_sent[0], "\n") && !strings.contains(fx_sent[0], "\r"), "no Enter")
	clear(&fx_sent)

	// an exited program in B: nothing, and said
	for &tab in s.tabs do if tab.id == 102 do tab.status = .Exited
	x, y, _ = fx_row("/a.txt")
	fx_drag(x, y, b.x, b.y)
	testing.expectf(t, len(fx_sent) == 0, "sent %v", fx_sent[:])
	testing.expect(t, strings.contains(toast.text, "not running"), toast.text)
	for &tab in s.tabs do if tab.id == 102 do tab.status = .Running

	// a release over no pane (the title bar above the panes): nothing anywhere
	x, y, _ = fx_row("/a.txt")
	fx_drag(x, y, b.x, 2)
	testing.expectf(t, len(fx_sent) == 0, "sent %v", fx_sent[:])
	testing.expect_value(t, pk_take(101), "")
	testing.expect_value(t, pk_take(102), "")
}

@(test)
files_drop_opens_in_an_editor_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	defer pk_reset()
	defer core.after_command_check = nil
	dir := fx_setup("editor")
	defer os.remove_all(dir)
	ap := fx_write(dir, "a.txt")
	_, b, a_id, b_id := fx_split()
	// B shows an editor (the tab's kind as drawn: Open here)
	s := core.cur()
	for &tab in s.tabs do if tab.id == 102 do tab.kind, tab.has_term = core.Editor_Tab{path = strings.clone(ap)}, false
	testing.expect_value(t, files_pane_target(b.x, b.y).action, core.Pane_Drop.Open_Here)
	fx_write(dir, "n.txt")
	x, y, ok := fx_row("/n.txt")
	if !testing.expect(t, ok, "row drawn") do return
	fx_drag(x, y, b.x, b.y)
	testing.expectf(t, len(fx_sent) == 0, "sent %v", fx_sent[:])
	s = core.cur()
	np := strings.concatenate({dir, "/n.txt"}, context.temp_allocator)
	found: u64
	for tab in s.tabs do if et, is := tab.kind.(core.Editor_Tab); is && et.path == np do found = tab.id
	testing.expectf(t, found != 0, "n.txt opened (toast %q)", toast.text)
	if found != 0 do testing.expect_value(t, core.pane_of_tab(s, found).id, b_id)
	testing.expect(t, core.pane_tab_count(s, a_id) == 1, "nothing opened in A")
}

@(test)
files_finder_drop_copies_into_the_tree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	defer pk_reset()
	defer core.after_command_check = nil
	dir := fx_setup("finder")
	defer os.remove_all(dir)
	outside := strings.concatenate({dir, "-outside"})
	defer os.remove_all(outside)
	os.make_directory_all(outside)
	fa := fx_write(outside, "photo.png")
	fd := filepath.dir(fx_write(outside, "notes/one.md"))
	fx_write(outside, "notes/.git/HEAD")
	fx_write(dir, "src/main.go")
	fx_write(dir, "photo.png")
	projects := len(state.projects)
	wait :: proc() {
		for i := 0; i < 400 && files_drops_busy(); i += 1 {
			core.inbox_drain()
			files_drops_tick()
			time.sleep(5 * time.Millisecond)
		}
	}

	// onto a folder row: into it (a file and a folder; the folder's .git left out and said)
	x, y, ok := fx_row("/src")
	if !testing.expect(t, ok, "row drawn") do return
	sidebar_drop({fa, fd}, x, y)
	wait()
	testing.expect(t, os.exists(strings.concatenate({dir, "/src/photo.png"}, context.temp_allocator)), "photo copied into src/")
	testing.expect(t, os.exists(strings.concatenate({dir, "/src/notes/one.md"}, context.temp_allocator)), "notes copied into src/")
	testing.expect(t, !os.exists(strings.concatenate({dir, "/src/notes/.git"}, context.temp_allocator)), ".git left out")
	testing.expect(t, strings.has_prefix(toast.text, "Copied photo.png, notes to src/"), toast.text)
	testing.expect(t, strings.contains(toast.text, "; left out: notes/.git (a git repository's folder)") && !toast.err, toast.text)
	testing.expect(t, os.exists(fa), "the source stays")
	testing.expect_value(t, len(state.projects), projects) // no project made

	// onto a file row: its folder; a name taken: "name copy"
	x, y, _ = fx_row("/photo.png")
	sidebar_drop({fa}, x, y)
	wait()
	testing.expect(t, os.exists(strings.concatenate({dir, "/photo copy.png"}, context.temp_allocator)), "photo copy.png at the root")
	testing.expect_value(t, toast.text, fmt.tprintf("Copied photo copy.png to %s/", filepath.base(dir)))

	// below the rows: the root
	fx_lay()
	lb := clay.GetElementData(clay.ID("files_list")).boundingBox
	sidebar_drop({fd}, lb.x + lb.width / 2, lb.y + lb.height - 8)
	wait()
	testing.expect(t, os.exists(strings.concatenate({dir, "/notes/one.md"}, context.temp_allocator)), "notes at the root")

	// a credential refused (the rest copied); the toast names both
	cred := fx_write(outside, ".credentials.json")
	fx_write(outside, "keep.txt")
	sidebar_drop({cred, strings.concatenate({outside, "/keep.txt"}, context.temp_allocator)}, lb.x + lb.width / 2, lb.y + lb.height - 8)
	wait()
	testing.expect(t, !os.exists(strings.concatenate({dir, "/.credentials.json"}, context.temp_allocator)), "the credential is not copied")
	testing.expect(t, os.exists(strings.concatenate({dir, "/keep.txt"}, context.temp_allocator)), "keep.txt copied")
	testing.expect_value(t, toast.text, fmt.tprintf("Copied keep.txt to %s/; not copied: .credentials.json: it is a credential: not copied", filepath.base(dir)))
	testing.expect(t, toast.err, "an error toast")

	// the hover: a Finder drag over a folder row bands it (and only while it hovers)
	x, y, _ = fx_row("/src")
	files_finder_hover(x, y, true)
	testing.expect(t, files_finder_band(strings.concatenate({dir, "/src/main.go"}, context.temp_allocator), false), "src's rows banded")
	testing.expect(t, !files_finder_band(strings.concatenate({dir, "/photo.png"}, context.temp_allocator), false), "not the others")
	files_finder_hover_end()
	testing.expect(t, !files_finder_band(strings.concatenate({dir, "/src/main.go"}, context.temp_allocator), false), "ended")

	// the Sessions tab: a folder becomes a project, as before (nothing copied)
	state.layout.left_tab = .Sessions
	fx_lay()
	sidebar_drop({fd}, x, y)
	core.inbox_drain()
	testing.expect_value(t, len(state.projects), projects + 1)
	testing.expect(t, !os.exists(strings.concatenate({dir, "/src/notes copy"}, context.temp_allocator)), "nothing copied")
}

// Review of #180: Open here keeps to the target pane. Pane A shows an editor; pane B's only tab is
// a.ts. Dropping a.ts and b.ts on A: a.ts stays in B (said), b.ts opens in A, and the keyboard
// ends in A (opening a.ts brings B forward on the way). At most FILES_OPEN_MAX open per drop.
@(test)
files_drop_open_here_keeps_the_target_pane :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	defer pk_reset()
	defer core.after_command_check = nil
	dir := fx_setup("openhere")
	defer os.remove_all(dir)
	xp := fx_write(dir, "x.txt")
	ap := fx_write(dir, "a.ts")
	bp := fx_write(dir, "b.ts")
	a, _, a_id, b_id := fx_split()
	s := core.cur()
	for &tab in s.tabs {
		if tab.id == 101 do tab.kind, tab.has_term = core.Editor_Tab{path = strings.clone(xp)}, false
		if tab.id == 102 do tab.kind, tab.has_term = core.Editor_Tab{path = strings.clone(ap)}, false
	}
	v := core.tree_view()
	core.files_select_in(v, ap)
	core.files_sel_set(v, {ap, bp})
	x, y, ok := fx_row("/a.ts")
	if !testing.expect(t, ok, "row drawn") do return
	fx_drag(x, y, a.x, a.y)
	s = core.cur()
	in_pane :: proc(s: ^core.Open_Session, path: string) -> u64 {
		for tab in s.tabs do if et, is := tab.kind.(core.Editor_Tab); is && et.path == path do return core.pane_of_tab(s, tab.id).id
		return 0
	}
	testing.expect_value(t, in_pane(s, bp), a_id)
	testing.expect_value(t, in_pane(s, ap), b_id)
	testing.expect_value(t, core.session_focused_pane(s).id, a_id)
	testing.expect(t, strings.contains(toast.text, "a.ts: open in another pane"), toast.text)

	// more than FILES_OPEN_MAX: the first ones open, the toast says how many
	paths := make([dynamic]string, context.temp_allocator)
	for i in 0 ..< int(FILES_OPEN_MAX + 5) do append(&paths, fx_write(dir, fmt.tprintf("m%02d.txt", i)))
	core.files_select_in(v, paths[0])
	core.files_sel_set(v, paths[:])
	x, y, _ = fx_row("/m00.txt")
	fx_drag(x, y, a.x, a.y)
	s = core.cur()
	n := 0
	for p in paths do if in_pane(s, p) == a_id do n += 1
	testing.expect_value(t, n, FILES_OPEN_MAX)
	testing.expect(t, strings.contains(toast.text, fmt.tprintf("Opened %d of %d", FILES_OPEN_MAX, FILES_OPEN_MAX + 5)), toast.text)
}

// Review of #180: no pane is a target under an overlay (the palette, a menu, settings, the
// shortcuts, setup, a peek, the notifications).
@(test)
files_drop_no_pane_under_an_overlay :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	defer pk_reset()
	defer core.after_command_check = nil
	dir := fx_setup("overlay")
	defer os.remove_all(dir)
	_, b, _, b_id := fx_split()
	testing.expect_value(t, files_pane_target(b.x, b.y).pane, b_id)
	for w in ([]string{"palette", "settings", "shortcuts", "notifications"}) {
		ui_do(core.Set_Focus{w})
		core.inbox_drain()
		testing.expectf(t, files_pane_target(b.x, b.y).pane == 0, "%s open: no target", w)
		ui_do(core.Set_Focus{""})
		core.inbox_drain()
	}
	testing.expect_value(t, files_pane_target(b.x, b.y).pane, b_id)
}

// Review of #180: the Finder copy queue never sticks. A copy whose finished never comes (the
// core went, or restarted: another link) ends the queue with a toast; so does one past
// DROPS_FOLLOW_MAX. A finished event that comes while no copy is being started is not kept.
@(test)
files_drops_queue_never_sticks :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	when core.TEST_HOOKS {
		defer files_drops_test_reset()
		// another link than the copy's (the core restarted)
		files_drops_test_waiting(77, time.tick_now(), rawptr(uintptr(0x10)))
		testing.expect(t, files_drops_busy(), "waiting")
		files_drops_tick()
		testing.expect(t, !files_drops_busy(), "the queue ended")
		testing.expect(t, strings.contains(toast.text, "stopped following"), toast.text)
		// past the deadline
		files_drops_test_waiting(78, time.tick_add(time.tick_now(), -(time.Duration(DROPS_FOLLOW_MAX) + time.Second)), nil)
		files_drops_tick()
		testing.expect(t, !files_drops_busy(), "the queue ended at the deadline")
		// an unrelated finished while a copy runs (not being started): not kept
		files_drops_test_waiting(79, time.tick_now(), nil)
		files_drops_on_event(core.Finished_Event{request_id = 5, result = {ok = true}})
		testing.expect_value(t, files_drops_test_kept(), 0)
		files_drops_on_event(core.Finished_Event{request_id = 79, result = {ok = true, data = `{"path":"/x/a.txt","copied":1}`}})
		testing.expect(t, !files_drops_busy(), "its own finished ends it")
		testing.expect(t, strings.contains(toast.text, "a.txt"), toast.text)
	}
}
