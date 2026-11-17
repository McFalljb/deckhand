package main

// The Files tree's clipboard and undo through event() (ui_files_clip.odin, ui_files_undo.odin):
// ⌘C then ⌘V with the tree's keyboard sends fs_copy and nothing to a terminal (the paste's text
// goes nowhere); ⌘X ⌘V moves; ⌘D duplicates; a drag with ⌥ at the release copies; ⌘⌫ asks
// nothing and ⌘Z puts it back; ⌘Z undoes in reverse; ⌘Z without the tree's keyboard is not the
// tree's.

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
FC_W :: 1400
@(private = "file")
FC_H :: 860

// Every command run (core.after_command_check), as its type, and send_text's as "send:tab:text".
@(private = "file")
fc_ran: [dynamic]string

@(private = "file")
fc_trash_dir: string

@(private = "file")
fc_setup :: proc() -> string {
	context.allocator = runtime.heap_allocator()
	pk_reset()
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/deckhand-fclip-%d", tmp, time.now()._nsec)
	os.make_directory_all(made)
	dir := core.fs_real(made, context.allocator)
	ensure(strings.contains(dir, "/deckhand-fclip-") && os.is_directory(dir), "files clip tests: no temp folder")
	state.projects[0].cwd = dir
	pk_session(100, "Here", pk_tab(101))
	state.open_sessions[0].cwd = strings.clone(dir)
	state.current_session = 100
	_ = pk_view(101, 80, 24)
	state.layout.left_tab = .Files
	core.files_refresh()
	core.files_state_gen += 1
	// a Trash of the test's own that says where it put each item (restore_path can bring it back)
	fc_trash_dir = fmt.aprintf("%s-trash", made)
	os.make_directory_all(fc_trash_dir)
	core.fs_trash_fn = proc(path: string) -> bool {
		to := fmt.tprintf("%s/%d-%s", fc_trash_dir, time.now()._nsec, filepath.base(path))
		if os.rename(path, to) != nil do return false
		core.fs_trash_where = core.fs_real(to)
		return true
	}
	clear(&fc_ran)
	core.after_command_check = proc(cmd: core.Command) {
		if st, is := cmd.(core.Send_Text); is do append(&fc_ran, fmt.aprintf("send:%d:%s", st.tab_id, st.text, allocator = runtime.heap_allocator()))
		else do append(&fc_ran, strings.clone(core.command_type(cmd), runtime.heap_allocator()))
	}
	return dir
}

@(private = "file")
fc_teardown :: proc(dir: string) {
	core.after_command_check = nil
	core.fs_trash_fn = nil
	os.remove_all(dir)
	os.remove_all(fc_trash_dir)
	pk_reset()
}

@(private = "file")
fc_write :: proc(dir, rel: string) {
	p := strings.concatenate({dir, "/", rel}, context.temp_allocator)
	os.make_directory_all(core.tdir(p))
	_ = os.write_entire_file(p, transmute([]u8)string("x"))
	core.files_path_changed(p)
}

@(private = "file")
fc_has :: proc(dir, rel: string) -> bool {return os.exists(strings.concatenate({dir, "/", rel}, context.temp_allocator))}

// A ⌘ key (mods: more) through event(), as the menu bar passes it on; v: a paste follows, as sokol sends it.
@(private = "file")
fc_key :: proc(code: sapp.Keycode, mods: u32 = 0) {
	m := sapp.MODIFIER_SUPER | mods
	e := sapp.Event{type = .KEY_DOWN, key_code = code, modifiers = m}
	event(&e)
	if code == .V && mods == 0 {
		p := sapp.Event{type = .CLIPBOARD_PASTED}
		event(&p)
	}
	u := sapp.Event{type = .KEY_UP, key_code = code, modifiers = m}
	event(&u)
	core.inbox_drain()
}

// Until the paste's copies are done (each fs_copy's finished, then files_copy_tick).
@(private = "file")
fc_wait_copy :: proc() {
	for _ in 0 ..< 1000 {
		core.inbox_drain()
		files_copy_tick()
		if !files_copy_running() do return
		time.sleep(5 * time.Millisecond)
	}
}

@(private = "file")
fc_select :: proc(dir, rel: string) {
	core.files_select_in(core.tree_view(), strings.concatenate({dir, "/", rel}, context.temp_allocator))
}

@(private = "file")
fc_focus :: proc(w: string) {
	ui_do(core.Set_Focus{w})
	core.inbox_drain()
}

@(private = "file")
fc_ran_has :: proc(what: string) -> bool {
	for r in fc_ran do if r == what do return true
	return false
}

@(private = "file")
fc_sent_any :: proc() -> bool {
	for r in fc_ran do if strings.has_prefix(r, "send:") do return true
	return false
}

@(test)
files_clip_paste_and_undo_through_event :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	dir := fc_setup()
	defer fc_teardown(dir)
	win_os.get_clipboard = proc() -> string {return "rm -rf ~"} // text on the system clipboard: never pasted anywhere here
	defer win_os.get_clipboard = nil
	win_os.set_clipboard = proc(s: string) {fc_clip_text = strings.clone(s, runtime.heap_allocator())}
	defer win_os.set_clipboard = nil
	fc_write(dir, "a.txt")
	fc_write(dir, "it's.txt")
	fc_write(dir, "src/keep.txt")
	_ = ui_layout(FC_W, FC_H)

	// ⌘V with an empty file clipboard: nothing (the system clipboard's text goes nowhere)
	fc_select(dir, "a.txt")
	fc_focus("files")
	fc_key(.V)
	testing.expect(t, !fc_sent_any(), "nothing reached a terminal")
	testing.expect(t, !fc_ran_has("fs_copy"), "nothing copied")
	testing.expect_value(t, pk_take(101), "")

	// ⌘C: the file clipboard, and the system clipboard's text shell-quoted
	core.files_sel_set(core.tree_view(), {strings.concatenate({dir, "/a.txt"}, context.temp_allocator), strings.concatenate({dir, "/it's.txt"}, context.temp_allocator)})
	fc_key(.C)
	testing.expect_value(t, fc_clip_text, fmt.tprintf("'%s/a.txt' '%s/it'\\''s.txt'", dir, dir))
	// ⌘V on the folder src: fs_copy per item, nothing to a terminal
	fc_select(dir, "src")
	clear(&fc_ran)
	fc_key(.V)
	fc_wait_copy()
	testing.expect(t, fc_ran_has("fs_copy"), "fs_copy sent")
	testing.expect(t, !fc_sent_any(), "nothing reached a terminal")
	testing.expect_value(t, pk_take(101), "")
	testing.expect(t, fc_has(dir, "src/a.txt") && fc_has(dir, "src/it's.txt") && fc_has(dir, "a.txt"), "copied into src/")
	testing.expect_value(t, toast.text, "Copied 2 items to src/")
	testing.expect_value(t, toast.action, "Undo")
	// again: the names are taken there now, "name copy"
	fc_key(.V)
	fc_wait_copy()
	testing.expect(t, fc_has(dir, "src/a copy.txt"), "a clash: a copy.txt")

	// ⌘Z: the last paste's copies go to the Trash, then the first's
	fc_key(.Z)
	testing.expect(t, !fc_has(dir, "src/a copy.txt") && fc_has(dir, "src/a.txt"), "undo: the second paste's copies")
	fc_key(.Z)
	testing.expect(t, !fc_has(dir, "src/a.txt") && fc_has(dir, "a.txt"), "undo: the first paste's copies")

	// ⌘X ⌘V moves; the cut row is dimmed meanwhile; ⌘Z moves it back
	fc_select(dir, "a.txt")
	fc_key(.X)
	testing.expect(t, files_clip_is_cut(strings.concatenate({dir, "/a.txt"}, context.temp_allocator)), "cut")
	ui_do(core.Files_Expand{path = strings.concatenate({dir, "/src"}, context.temp_allocator), expanded = true})
	core.inbox_drain()
	core.files_refresh()
	fc_select(dir, "src/keep.txt") // a file (a row that shows): into its folder
	fc_key(.V)
	testing.expect(t, fc_has(dir, "src/a.txt") && !fc_has(dir, "a.txt"), "moved into src/")
	testing.expect(t, !files_clip_has(), "a cut is pasted once")
	fc_key(.Z)
	testing.expect(t, fc_has(dir, "a.txt") && !fc_has(dir, "src/a.txt"), "undo: moved back")

	// ⌘D duplicates in place
	fc_select(dir, "a.txt")
	fc_key(.D)
	fc_wait_copy()
	testing.expect(t, fc_has(dir, "a copy.txt"), "duplicated")

	// ⌘Z without the tree's keyboard (a terminal's, an editor's): not the tree's
	fc_focus("")
	fc_key(.Z)
	testing.expect(t, fc_has(dir, "a copy.txt"), "⌘Z outside the tree undoes nothing in it")
	fc_focus("files")
	fc_key(.Z)
	testing.expect(t, !fc_has(dir, "a copy.txt"), "with the tree's keyboard: undone")

	// ⌘⌫: no confirmation (the core can put it back), Undo puts it back
	fc_select(dir, "it's.txt")
	n := len(state.pending_confirmations)
	fc_key(.BACKSPACE)
	testing.expect_value(t, len(state.pending_confirmations), n)
	testing.expect(t, !fc_has(dir, "it's.txt"), "moved to the Trash without asking")
	testing.expect_value(t, toast.text, "Moved it's.txt to the Trash")
	fc_key(.Z)
	testing.expect(t, fc_has(dir, "it's.txt"), "undo: put back from the Trash")
	testing.expect(t, !fc_sent_any(), "nothing reached a terminal")

	// Review round 1: a cut is its tree's only. Another project on screen drops it (and its
	// dimming); back in the first tree nothing is cut any more, nothing moves
	fc_select(dir, "a.txt")
	fc_key(.X)
	other := fmt.aprintf("%s-other", dir)
	os.make_directory_all(other)
	defer os.remove_all(other)
	append(&state.projects, core.Project{id = 2, cwd = strings.clone(other), label = "other"})
	state.open_sessions[0].cwd = strings.clone(other)
	core.files_refresh()
	core.files_state_gen += 1
	testing.expect(t, !files_clip_is_cut(strings.concatenate({dir, "/a.txt"}, context.temp_allocator)), "another tree: the cut is dropped")
	fc_key(.V)
	testing.expect(t, fc_has(dir, "a.txt") && !os.exists(fmt.tprintf("%s/a.txt", other)), "nothing moved into the other project")
	state.open_sessions[0].cwd = strings.clone(dir)
	core.files_refresh()
	core.files_state_gen += 1

	// P3 (a): Paste from the empty space's menu (the root's) goes to the root, not the selected folder
	fc_select(dir, "src/keep.txt")
	fc_key(.C)
	fc_select(dir, "src")
	files_clip_step(dir, .Paste)
	fc_wait_copy()
	testing.expect(t, fc_has(dir, "keep.txt"), "pasted into the root")
}

@(private = "file")
fc_clip_text: string

// The centre of the drawn row whose path ends with suffix, after a layout.
@(private = "file")
fc_row :: proc(suffix: string) -> (x, y: f32, ok: bool) {
	_ = ui_layout(FC_W, FC_H)
	slot := files_drawn_slot(suffix)
	if slot < 0 do return
	d := clay.GetElementData(clay.ID("frow", u32(slot)))
	if !d.found do return
	b := d.boundingBox
	return b.x + b.width / 2, b.y + b.height / 2, true
}

@(private = "file")
fc_ev :: proc(type: sapp.Event_Type, x, y: f32, mods: u32 = 0) {
	e := sapp.Event{type = type, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = mods}
	event(&e)
	core.inbox_drain()
}

@(test)
files_clip_alt_drag_copies :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	dir := fc_setup()
	defer fc_teardown(dir)
	fc_write(dir, "b.txt")
	fc_write(dir, "lib/x.go")
	bx, by, ok1 := fc_row("/b.txt")
	lx, ly, ok2 := fc_row("/lib")
	if !testing.expect(t, ok1 && ok2, "rows drawn") do return
	fc_ev(.MOUSE_DOWN, bx, by)
	_ = ui_layout(FC_W, FC_H)
	fc_ev(.MOUSE_MOVE, bx, by + 12, sapp.MODIFIER_LMB)
	_ = ui_layout(FC_W, FC_H)
	fc_ev(.MOUSE_MOVE, lx, ly, sapp.MODIFIER_LMB | sapp.MODIFIER_ALT)
	testing.expect(t, files_drag_copy, "⌥ held: a copy")
	fc_ev(.MOUSE_UP, lx, ly, sapp.MODIFIER_ALT) // read at the release
	fc_wait_copy()
	testing.expect(t, fc_has(dir, "lib/b.txt") && fc_has(dir, "b.txt"), "copied, the source stays")
	// ⌥ let go before the release: a move
	bx, by, _ = fc_row("/b.txt")
	lx, ly, _ = fc_row("/lib")
	fc_ev(.MOUSE_DOWN, bx, by)
	_ = ui_layout(FC_W, FC_H)
	fc_ev(.MOUSE_MOVE, bx, by + 12, sapp.MODIFIER_LMB | sapp.MODIFIER_ALT)
	_ = ui_layout(FC_W, FC_H)
	fc_ev(.MOUSE_MOVE, lx, ly, sapp.MODIFIER_LMB | sapp.MODIFIER_ALT)
	fc_ev(.MOUSE_UP, lx, ly)
	testing.expect(t, fc_has(dir, "b.txt"), "a move's rules: lib/ already has b.txt")
	testing.expect(t, strings.contains(toast.text, "Not moved: lib/ already has b.txt"), toast.text)
	// ⌥ onto its own folder (a row next to it): a duplicate, never a no-op
	bx, by, _ = fc_row("/b.txt")
	lx, ly, _ = fc_row("/lib/x.go")
	if lx == 0 {
		ui_do(core.Files_Expand{path = strings.concatenate({dir, "/lib"}, context.temp_allocator), expanded = true})
		core.inbox_drain()
	}
	bx, by, _ = fc_row("/lib/b.txt")
	lx, ly, _ = fc_row("/lib/x.go")
	fc_ev(.MOUSE_DOWN, bx, by)
	_ = ui_layout(FC_W, FC_H)
	fc_ev(.MOUSE_MOVE, bx, by + 12, sapp.MODIFIER_LMB | sapp.MODIFIER_ALT)
	_ = ui_layout(FC_W, FC_H)
	fc_ev(.MOUSE_MOVE, lx, ly, sapp.MODIFIER_LMB | sapp.MODIFIER_ALT)
	fc_ev(.MOUSE_UP, lx, ly, sapp.MODIFIER_ALT)
	fc_wait_copy()
	testing.expect(t, fc_has(dir, "lib/b copy.txt"), "a duplicate in its own folder")
}
