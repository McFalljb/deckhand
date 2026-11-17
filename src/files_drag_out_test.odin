package main

// A Files drag out of the window (files_drag_out.odin, src/native/dragout_macos.m): what it
// carries (paths inside the tree's project, nested ones once, no credential files), the picture's
// label, Copy only and only to other apps, the pasteboard items as AppKit reads them back, and
// through event(): the in-window drag ends when the pointer leaves, nothing moves, and the release
// after it reaches nothing.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:sys/posix"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(test)
files_drag_out_what_it_carries :: proc(t: ^testing.T) {
	no_creds :: proc(p: string) -> Files_Out_Refusal {return .None}
	// inside the root only, not the root itself; a folder carries what is in it (once)
	paths, refused := files_drag_out_paths("/p/proj", {"/p/proj/a.txt", "/p/proj/src", "/p/proj/src/x.go", "/p/proj", "/p/other/b", "/p/proj-2/c"}, no_creds)
	testing.expect_value(t, len(paths), 2)
	if len(paths) == 2 {
		testing.expect_value(t, paths[0], "/p/proj/a.txt")
		testing.expect_value(t, paths[1], "/p/proj/src")
	}
	testing.expect_value(t, len(refused), 0)
	// refused items are left out, with why
	creds :: proc(p: string) -> Files_Out_Refusal {return strings.has_suffix(p, "auth.json") ? .Credentials : strings.has_suffix(p, "big") ? .Too_Large : .None}
	paths, refused = files_drag_out_paths("/p/proj", {"/p/proj/auth.json", "/p/proj/a.txt"}, creds)
	testing.expect_value(t, len(paths), 1)
	testing.expect_value(t, len(refused), 1)
	testing.expect_value(t, files_drag_out_refused_text(refused), "auth.json not dragged: credentials")
	paths, refused = files_drag_out_paths("/p/proj", {"/p/proj/auth.json", "/p/proj/x/auth.json"}, creds)
	testing.expect_value(t, len(paths), 0)
	testing.expect_value(t, files_drag_out_refused_text(refused), "2 not dragged: credentials")
	paths, refused = files_drag_out_paths("/p/proj", {"/p/proj/auth.json", "/p/proj/big"}, creds)
	testing.expect_value(t, files_drag_out_refused_text(refused), "2 not dragged: credentials, or too large to check")
	// no root (the tree shows another one than the drag's): nothing
	paths, _ = files_drag_out_paths("", {"/p/proj/a.txt"}, no_creds)
	testing.expect_value(t, len(paths), 0)

	// the text: every path quoted, one line
	testing.expect_value(t, files_drag_out_text({"/p/a b", "/p/it's"}), `'/p/a b' '/p/it'\''s'`)

	testing.expect_value(t, files_drag_out_label({"/p/proj/a.txt"}), "a.txt")
	testing.expect_value(t, files_drag_out_label({"/p/proj/a\nb.txt"}), "a b.txt") // a name is one line
	testing.expect_value(t, files_drag_out_label({"/p/a", "/p/b", "/p/c"}), "3 items")

	testing.expect(t, !files_drag_out_outside(0, 0, 100, 50), "the corner is inside")
	testing.expect(t, files_drag_out_outside(-1, 10, 100, 50) && files_drag_out_outside(10, -1, 100, 50), "left, above")
	testing.expect(t, files_drag_out_outside(100, 10, 100, 50) && files_drag_out_outside(10, 50, 100, 50), "right, below")
}

@(test)
files_drag_out_native :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	// Copy (1) to other apps; nothing inside Deckhand (no drop of our own files on our window)
	testing.expect_value(t, platform_drag_out_mask(true), 1)
	testing.expect_value(t, platform_drag_out_mask(false), 0)
	// the items: a file URL each (percent-encoded); the text, one line, on the first only
	when core.TEST_HOOKS {
		paths := []string{"/tmp/dh drag/a b.txt", "/tmp/dh drag/it's"}
		got, ok := platform_drag_out_test_items(paths, files_drag_out_text(paths))
		if !testing.expect(t, ok, "a pasteboard") do return
		testing.expect_value(t, got, "file:///tmp/dh%20drag/a%20b.txt\t'/tmp/dh drag/a b.txt' '/tmp/dh drag/it'\\''s'\nfile:///tmp/dh%20drag/it's\t\n")
	}
}

// What a dragged folder holds, checked all through (files_out_walk): a .codex folder with its
// auth.json deep inside, a link to pi's auth.json, a hard link to it, a link to a credential
// folder; a clean folder goes; too many entries, too deep, or unreadable: refused (fail closed).
@(test)
files_drag_out_credentials_inside :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/deckhand-fout-creds-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(fmt.tprintf("%s/home", made))
	base := core.fs_real(made, context.allocator)
	if !testing.expect(t, strings.contains(base, "/deckhand-fout-creds-"), "a temp folder") do return
	defer os.remove_all(base)
	home := fmt.aprintf("%s/home", base)
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator))
	defer {os.set_env("HOME", old_home); delete(old_home)}
	os.set_env("HOME", home) // never the user's own ~/.pi or ~/.codex
	old_pi, had_pi := os.lookup_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	defer {if had_pi do os.set_env("PI_CODING_AGENT_DIR", old_pi); else do os.unset_env("PI_CODING_AGENT_DIR")}
	os.unset_env("PI_CODING_AGENT_DIR")
	old_cx, had_cx := os.lookup_env("CODEX_HOME", context.temp_allocator)
	defer {if had_cx do os.set_env("CODEX_HOME", old_cx); else do os.unset_env("CODEX_HOME")}
	os.unset_env("CODEX_HOME")
	put :: proc(p: string) {
		os.make_directory_all(filepath.dir(p))
		_ = os.write_entire_file(p, transmute([]u8)string("x"))
	}
	h :: proc(home, rel: string) -> string {return fmt.tprintf("%s/%s", home, rel)}
	put(h(home, ".pi/agent/auth.json")) // pi's sign-in
	put(h(home, ".codex/auth.json"))
	put(h(home, "proj/ops/fixtures/home/.codex/auth.json"))
	put(h(home, "proj/ops/readme.md"))
	os.make_directory_all(h(home, "proj/ops2/conf"))
	posix.symlink(strings.clone_to_cstring(h(home, ".pi/agent/auth.json"), context.temp_allocator), strings.clone_to_cstring(h(home, "proj/ops2/conf/auth.json"), context.temp_allocator))
	os.make_directory_all(h(home, "proj/ops3/conf"))
	posix.link(strings.clone_to_cstring(h(home, ".pi/agent/auth.json"), context.temp_allocator), strings.clone_to_cstring(h(home, "proj/ops3/conf/x"), context.temp_allocator))
	os.make_directory_all(h(home, "proj/ops4"))
	posix.symlink(strings.clone_to_cstring(h(home, ".codex"), context.temp_allocator), strings.clone_to_cstring(h(home, "proj/ops4/cx"), context.temp_allocator))
	put(h(home, "proj/clean/a/b/c.txt"))
	put(h(home, "proj/clean/d.txt"))
	ids := core.credential_ids()
	testing.expect_value(t, files_out_check(h(home, "proj/ops"), ids), Files_Out_Refusal.Credentials)
	testing.expect_value(t, files_out_check(h(home, "proj/ops2"), ids), Files_Out_Refusal.Credentials)
	testing.expect_value(t, files_out_check(h(home, "proj/ops3"), ids), Files_Out_Refusal.Credentials)
	testing.expect_value(t, files_out_check(h(home, "proj/ops4"), ids), Files_Out_Refusal.Credentials)
	testing.expect_value(t, files_out_check(h(home, "proj/ops3/conf/x"), ids), Files_Out_Refusal.Credentials) // the hard link itself
	testing.expect_value(t, files_out_check(h(home, "proj/ops/readme.md"), ids), Files_Out_Refusal.None)
	testing.expect_value(t, files_out_check(h(home, "proj/clean"), ids), Files_Out_Refusal.None)
	// the walk's own check of places by where they are (one inside the dragged folder)
	put(h(home, "proj/tools/agent/sessions/s.jsonl"))
	testing.expect_value(t, files_out_walk(h(home, "proj/tools"), ids, {h(home, "proj/tools/agent")}), Files_Out_Refusal.Credentials)
	testing.expect_value(t, files_out_walk(h(home, "proj/tools"), ids, {}), Files_Out_Refusal.None)
	// fail closed: too many entries, too deep, unreadable
	testing.expect_value(t, files_out_check(h(home, "proj/clean"), ids, max_entries = 3), Files_Out_Refusal.Too_Large)
	testing.expect_value(t, files_out_check(h(home, "proj/clean"), ids, max_depth = 1), Files_Out_Refusal.Too_Large)
	put(h(home, "proj/locked/in/x.txt"))
	posix.chmod(strings.clone_to_cstring(h(home, "proj/locked/in"), context.temp_allocator), {})
	defer posix.chmod(strings.clone_to_cstring(h(home, "proj/locked/in"), context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	if posix.getuid() != 0 do testing.expect_value(t, files_out_check(h(home, "proj/locked"), ids), Files_Out_Refusal.Unreadable)
	// the toast names the folder
	testing.expect_value(t, files_drag_out_refused_text({{h(home, "proj/ops"), .Credentials}}), "ops/ not dragged: it holds credentials")
	testing.expect_value(t, files_drag_out_refused_text({{h(home, "proj/clean"), .Too_Large}}), "clean/ not dragged: too large to check")
}

// A session on screen in a fresh temp folder, the Files tab showing (as files_drag_test.odin's).
@(private = "file")
fo_setup :: proc() -> string {
	context.allocator = runtime.heap_allocator()
	pk_reset()
	tmp := os.get_env("TMPDIR", context.temp_allocator)
	if tmp == "" do tmp = "/tmp"
	made := fmt.tprintf("%s/deckhand-fout-%d", strings.trim_right(tmp, "/"), time.now()._nsec)
	os.make_directory_all(made)
	dir := core.fs_real(made, context.allocator)
	ensure(strings.contains(dir, "/deckhand-fout-") && os.is_directory(dir), "files drag out tests: no temp folder")
	state.projects[0].cwd = dir
	pk_session(100, "Here", pk_tab(101))
	state.open_sessions[0].cwd = strings.clone(dir)
	state.current_session = 100
	_ = pk_view(101, 80, 24)
	state.layout.left_tab = .Files
	core.files_refresh()
	core.files_state_gen += 1
	return dir
}

@(private = "file")
fo_ev :: proc(type: sapp.Event_Type, x, y: f32, mods: u32 = 0) {
	e := sapp.Event{type = type, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = mods}
	event(&e)
	core.inbox_drain()
}

@(test)
files_drag_out_from_the_tree :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	if !testing.expect(t, audit_ui(), "fonts") do return
	when !core.TEST_HOOKS do return
	when core.TEST_HOOKS {
		W, H :: 1400, 860
		defer pk_reset()
		files_out_test = {on = true, w = W, h = H}
		defer files_out_test = {}
		defer files_out = {}
		dir := fo_setup()
		for n in ([]string{"a.txt", "lib/x.go"}) {
			p, _ := filepath.join({dir, n}, context.temp_allocator)
			os.make_directory_all(filepath.dir(p))
			_ = os.write_entire_file(p, transmute([]u8)string("x"))
			core.files_path_changed(p)
		}
		_ = ui_layout(W, H)
		slot := files_drawn_slot("/a.txt")
		if !testing.expect(t, slot >= 0, "a.txt drawn") do return
		b := clay.GetElementData(clay.ID("frow", u32(slot))).boundingBox
		ax, ay := b.x + b.width / 2, b.y + b.height / 2

		// a drag from a.txt that leaves the window (to the left): the system's drag carries a.txt
		fo_ev(.MOUSE_DOWN, ax, ay)
		_ = ui_layout(W, H)
		fo_ev(.MOUSE_MOVE, ax, ay + 12, sapp.MODIFIER_LMB)
		testing.expect(t, files_dragging() && !files_out_test.started, "an in-window drag first")
		fo_ev(.MOUSE_MOVE, -4, ay, sapp.MODIFIER_LMB)
		testing.expect(t, files_out_test.started, "the system's drag started")
		testing.expect(t, !files_dragging(), "the in-window drag ended")
		a := strings.concatenate({dir, "/a.txt"}, context.temp_allocator)
		testing.expect(t, len(files_out_test.paths) == 1 && files_out_test.paths[0] == a, "it carries a.txt")
		testing.expect_value(t, files_out_test.text, shell_quote(a))
		testing.expect_value(t, files_out_test.label, "a.txt")

		// the release (AppKit's own, or the one sent to let go of sokol's button) reaches nothing:
		// nothing moves, nothing goes to the terminal; the next press ends that
		_ = pk_take(101)
		e := sapp.Event{type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = 700, mouse_y = 400}
		testing.expect(t, files_drag_out_event(&e), "the release is eaten")
		fo_ev(.MOUSE_UP, 700, 400)
		testing.expect(t, os.exists(a), "nothing moved")
		testing.expect_value(t, pk_take(101), "")
		testing.expect(t, files_out.eat_release, "until the next press")
		fo_ev(.MOUSE_DOWN, ax, ay)
		testing.expect(t, !files_out.eat_release, "a press ends it")
		fo_ev(.MOUSE_UP, ax, ay)

		// the system's drag cannot start: the in-window drag goes on, a toast says so, no release
		// is eaten; leaving again in the same press tries no more
		files_out_test.fail, files_out_test.started = true, false
		toast_clear()
		fo_ev(.MOUSE_DOWN, ax, ay)
		_ = ui_layout(W, H)
		fo_ev(.MOUSE_MOVE, ax, ay + 12, sapp.MODIFIER_LMB)
		fo_ev(.MOUSE_MOVE, -4, ay, sapp.MODIFIER_LMB)
		testing.expect(t, !files_out_test.started, "not started")
		testing.expect(t, files_dragging(), "the in-window drag goes on")
		testing.expect_value(t, toast.text, "Could not start the drag")
		testing.expect(t, !files_out.eat_release, "no release eaten")
		toast_clear()
		fo_ev(.MOUSE_MOVE, -8, ay, sapp.MODIFIER_LMB)
		testing.expect_value(t, toast.text, "") // once per press
		fo_ev(.MOUSE_UP, -8, ay)
		testing.expect(t, !files_dragging() && os.exists(a), "released outside: nothing moved")
		os.remove_all(dir)
	}
}
