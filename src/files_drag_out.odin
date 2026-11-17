package main

// Dragging Files rows out of the window (macOS: src/native/dragout_macos.m). A tree drag whose
// pointer leaves the window becomes the system's own drag: the dragged files (the paths captured
// at the press, inside the tree's project) go to Finder, a terminal, another app or a browser's
// upload field, as copies (never moved out). The in-window drag ends there. Back over Deckhand's
// window the drag offers nothing.
//
// Never put on it: a credential file, a folder at, above or inside a credential place
// (fs_credential_place), and a folder holding one anywhere inside (files_out_walk: every entry,
// links not followed but checked where they lead, hard links by their inode). A folder too large
// or too deep to check, or one that cannot be read through, is left out too (fail closed).
//
// After a system drag starts, and until the next press, a release that reaches the window goes
// nowhere: AppKit's drag takes the real one, and the release the native side sends to let go of
// sokol's button (dragout_macos.m) must never reach a pane or terminal; that one is eaten whenever
// it comes.

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

Files_Drag_Out :: struct {
	eat_release: bool, // a system drag of ours started: releases go nowhere until the next press
	tried:       bool, // this press's drag left the window already (started, refused or failed)
}
files_out: Files_Drag_Out
@(private = "file")
files_out_ids: []core.Cred_Id // pi's sign-ins, read once per drag out (files_drag_out)

// Why an item is not dragged out.
Files_Out_Refusal :: enum {
	None,
	Credentials, // a credential file or place, or a folder holding one
	Too_Large,   // a folder with more than FILES_OUT_WALK_MAX entries, or deeper than FILES_OUT_WALK_DEPTH
	Unreadable,  // a folder that could not be read through
}

// The walk of a dragged folder (files_out_walk): at most this many entries, this deep. It runs on
// the main thread when the pointer leaves the window, once per press: 20,000 entries took 115 ms
// (few folders) to 190 ms (6,600 folders of 2 files) on a busy M-series Mac, so the cap is half
// that (a hitch of at most about 100 ms); past it the folder is not dragged ("too large to check").
FILES_OUT_WALK_MAX :: 10_000
FILES_OUT_WALK_DEPTH :: 24

// What a drag out carries, from the drag's sources (captured at the press) and the root they were
// captured in: those inside root (not root itself; nested ones once) that check lets through.
// refused: the others, with why. Temp allocator.
files_drag_out_paths :: proc(root: string, sources: []string, check: proc(path: string) -> Files_Out_Refusal) -> (paths: []string, refused: []Files_Out_Refused) {
	out := make([dynamic]string, context.temp_allocator)
	no := make([dynamic]Files_Out_Refused, context.temp_allocator)
	if root == "" do return out[:], no[:]
	inside := make([dynamic]string, context.temp_allocator) // first: the root itself would hold every other
	for s in sources do if s != root && core.within(s, root) do append(&inside, s)
	for s in core.files_drop_sources(inside[:]) {
		if r := check(s); r != .None do append(&no, Files_Out_Refused{s, r})
		else do append(&out, s)
	}
	return out[:], no[:]
}

Files_Out_Refused :: struct {
	path: string,
	why:  Files_Out_Refusal,
}

// The toast for items left out ("ops/ not dragged: it holds credentials", "3 not dragged: …").
files_drag_out_refused_text :: proc(refused: []Files_Out_Refused) -> string {
	if len(refused) == 0 do return ""
	if len(refused) > 1 {
		same := true
		for r in refused do same = same && r.why == refused[0].why
		if !same do return fmt.tprintf("%d not dragged: credentials, or too large to check", len(refused))
		#partial switch refused[0].why {
		case .Credentials: return fmt.tprintf("%d not dragged: credentials", len(refused))
		case .Too_Large:   return fmt.tprintf("%d not dragged: too large to check", len(refused))
		case:              return fmt.tprintf("%d not dragged: could not be checked", len(refused))
		}
	}
	r := refused[0]
	dir := core.path_kind(r.path) == .Dir
	name := core.one_line(filepath.base(r.path), context.temp_allocator)
	if dir do name = strings.concatenate({name, "/"}, context.temp_allocator)
	#partial switch r.why {
	case .Credentials: return fmt.tprintf("%s not dragged: %s", name, dir ? "it holds credentials" : "credentials")
	case .Too_Large:   return fmt.tprintf("%s not dragged: too large to check", name)
	case:              return fmt.tprintf("%s not dragged: could not be checked", name)
	}
}

// Whether a dragged item may go out: the item by its path (and where a link leads), then, for a
// folder (not a link to one), everything inside it (files_out_walk). ids: core.credential_ids().
files_out_check :: proc(path: string, ids: []core.Cred_Id, max_entries := FILES_OUT_WALK_MAX, max_depth := FILES_OUT_WALK_DEPTH) -> Files_Out_Refusal {
	if core.settings_credential(path, ids) || core.fs_credential_place(path) do return .Credentials
	st: posix.stat_t
	if posix.lstat(strings.clone_to_cstring(path, context.temp_allocator), &st) != .OK do return .Unreadable
	if !posix.S_ISDIR(st.st_mode) do return .None
	return files_out_walk(path, ids, core.fs_credential_place_paths(), max_entries, max_depth)
}

// Everything inside the folder top: a folder that is a credential place (by where it is or what it
// holds), a link that leads to a credential file or place, a file that is one of pi's sign-ins
// under another name (a hard link: its inode) or by its path. Links are not followed. Past
// max_entries entries or max_depth levels: Too_Large; a folder or entry that cannot be read:
// Unreadable.
// places: core.fs_credential_place_paths() (read once: fs_credential_place per folder would read
// them again each time). The folders inside top are reached through no link, so their paths are as
// real as top's: a place's path compares as it is.
files_out_walk :: proc(top: string, ids: []core.Cred_Id, places: []string, max_entries := FILES_OUT_WALK_MAX, max_depth := FILES_OUT_WALK_DEPTH) -> Files_Out_Refusal {
	Dir :: struct {
		path:  string,
		depth: int,
	}
	stack := make([dynamic]Dir, context.temp_allocator)
	append(&stack, Dir{top, 0})
	n := 0
	one_dir :: proc(d: Dir, stack: ^[dynamic]Dir, n: ^int, ids: []core.Cred_Id, places: []string, max_entries, max_depth: int) -> Files_Out_Refusal {
		// a place by where it is (at, above or inside one), or by what it holds (top's own folders
		// above it were checked with the item)
		for x in places do if core.within(x, d.path) || core.within(d.path, x) do return .Credentials
		if core.fs_credential_holder(d.path) do return .Credentials
		dp := posix.opendir(strings.clone_to_cstring(d.path, context.temp_allocator))
		if dp == nil do return .Unreadable
		defer posix.closedir(dp)
		fd := posix.dirfd(dp)
		for {
			posix.set_errno(nil)
			ent := posix.readdir(dp)
			if ent == nil {
				if posix.errno() != nil do return .Unreadable
				return .None
			}
			cname := cstring(raw_data(ent.d_name[:]))
			if cname == "." || cname == ".." do continue
			n^ += 1
			if n^ > max_entries do return .Too_Large
			p := strings.concatenate({d.path, "/", string(cname)}, context.temp_allocator)
			st: posix.stat_t
			if posix.fstatat(fd, cname, &st, {.SYMLINK_NOFOLLOW}) != .OK {
				if posix.errno() == .ENOENT do continue // gone since readdir
				return .Unreadable
			}
			switch {
			case posix.S_ISDIR(st.st_mode):
				if d.depth + 1 > max_depth do return .Too_Large
				append(stack, Dir{p, d.depth + 1})
			case posix.S_ISLNK(st.st_mode):
				if core.settings_credential(p, ids) || core.fs_credential_place(p) do return .Credentials
			case:
				// by its path it would be in pi's agent folder, a place (its folder was checked);
				// under another name: its inode (ids as read once: never read again per file)
				for c in ids do if c.dev == u64(st.st_dev) && c.inode == u64(st.st_ino) do return .Credentials
			}
		}
	}
	for len(stack) > 0 {
		d := pop(&stack)
		if r := one_dir(d, &stack, &n, ids, places, max_entries, max_depth); r != .None do return r
	}
	return .None
}

// The drag's picture: the one name, or "N items".
files_drag_out_label :: proc(paths: []string) -> string {
	if len(paths) == 1 do return core.one_line(filepath.base(paths[0]), context.temp_allocator)
	return fmt.tprintf("%d items", len(paths))
}

// The drag's text (apps that take text only): every path shell-quoted, on one line.
files_drag_out_text :: proc(paths: []string) -> string {
	q := make([]string, len(paths), context.temp_allocator)
	for p, i in paths do q[i] = shell_quote(p)
	return strings.join(q, " ", context.temp_allocator)
}

// The pointer at (x, y) is outside a w x h window (sokol's pixels).
files_drag_out_outside :: proc(x, y, w, h: f32) -> bool {return x < 0 || y < 0 || x >= w || y >= h}

when core.TEST_HOOKS {
	// Tests: a stand-in for the system drag (no window): the window's size, whether it fails to
	// start, and what would have been dragged (temp copies).
	Files_Drag_Out_Test :: struct {
		on:      bool,
		w, h:    f32,
		fail:    bool,
		started: bool,
		paths:   []string,
		text:    string,
		label:   string,
	}
	files_out_test: Files_Drag_Out_Test
}

// A tree drag moved to (x, y) (ui_files.odin, the drag's sources and the root they were captured
// in): outside the window, once per press, the system's drag starts with what it carries. True:
// it started, and the in-window drag is to end. Else the in-window drag goes on (nothing may go
// out: a toast says why; or it could not start: a toast says so).
files_drag_out :: proc(x, y: f32, root: string, sources: []string) -> bool {
	w, h: f32
	testing := false
	when core.TEST_HOOKS {
		if files_out_test.on {
			w, h, testing = files_out_test.w, files_out_test.h, true
		}
	}
	if !testing {
		if !sapp.isvalid() || !platform_drag_out_supported() do return false
		w, h = sapp.widthf(), sapp.heightf()
	}
	if files_out.tried || !files_drag_out_outside(x, y, w, h) do return false
	files_out.tried = true
	files_out_ids = core.credential_ids() // once for every item and entry
	check :: proc(p: string) -> Files_Out_Refusal {return files_out_check(p, files_out_ids)}
	paths, refused := files_drag_out_paths(root == core.files_root() ? root : "", sources, check)
	if len(refused) > 0 do toast_show(files_drag_out_refused_text(refused), err = true)
	if len(paths) == 0 do return false
	text, label := files_drag_out_text(paths), files_drag_out_label(paths)
	ok: bool
	when core.TEST_HOOKS {
		if testing {
			ok = !files_out_test.fail
			if ok do files_out_test.started, files_out_test.paths, files_out_test.text, files_out_test.label = true, paths, text, label
		}
	}
	if !testing do ok = platform_drag_out_begin(paths, text, label)
	if !ok {
		toast_show("Could not start the drag", err = true)
		return false
	}
	files_out.eat_release = true
	return true
}

// Every event, first in event() (main.odin): while a system drag of ours is on, nothing dropped
// on the window is taken (our own files back on the window); the release sent to let go of
// sokol's button never goes anywhere, and after a drag out no release does until the next press.
// True: taken.
files_drag_out_event :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .MOUSE_DOWN:
		files_out.eat_release, files_out.tried = false, false
	case .MOUSE_UP:
		if files_out.eat_release || platform_drag_out_synthetic() {
			app.redraw = true
			return true
		}
	case .FILES_DROPPED:
		return platform_drag_out_active()
	}
	return false
}
