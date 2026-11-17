package main

// Dragging Files rows out of the window (macOS: src/native/dragout_macos.m). A tree drag whose
// pointer leaves the window becomes the system's own drag: the dragged files (the paths captured
// at the press, inside the tree's project) go to Finder, a terminal, another app or a browser's
// upload field, as copies (never moved out). The in-window drag ends there. Credential files, and
// folders at, above or inside a credential place (fs_credential_place), are never put on it. Back
// over Deckhand's window the drag offers nothing.
//
// While the system drag is on, and until the next press, a release that reaches the window goes
// nowhere: AppKit's drag takes the real one, and the release the native side sends to let go of
// sokol's button (dragout_macos.m) must never reach a pane or terminal.

import "core:fmt"
import "core:path/filepath"
import "core:strings"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

Files_Drag_Out :: struct {
	eat_release: bool, // a system drag of ours started: releases go nowhere until the next press
}
files_out: Files_Drag_Out

// What a drag out carries, from the drag's sources (captured at the press) and the root they were
// captured in: those inside root (not root itself; nested ones once), without credential files
// (skipped counts them). Temp allocator.
files_drag_out_paths :: proc(root: string, sources: []string, credential: proc(path: string) -> bool) -> (paths: []string, skipped: int) {
	out := make([dynamic]string, context.temp_allocator)
	if root == "" do return out[:], 0
	inside := make([dynamic]string, context.temp_allocator) // first: the root itself would hold every other
	for s in sources do if s != root && core.within(s, root) do append(&inside, s)
	for s in core.files_drop_sources(inside[:]) {
		if credential(s) {
			skipped += 1
			continue
		}
		append(&out, s)
	}
	return out[:], skipped
}

// The drag's picture: the one name, or "N items".
files_drag_out_label :: proc(paths: []string) -> string {
	if len(paths) == 1 do return core.one_line(filepath.base(paths[0]), context.temp_allocator)
	return fmt.tprintf("%d items", len(paths))
}

// The pointer at (x, y) is outside a w x h window (sokol's pixels).
files_drag_out_outside :: proc(x, y, w, h: f32) -> bool {return x < 0 || y < 0 || x >= w || y >= h}

when core.TEST_HOOKS {
	// Tests: a stand-in for the system drag (no window): the window's size, and what would have
	// been dragged (temp copies).
	Files_Drag_Out_Test :: struct {
		on:      bool,
		w, h:    f32,
		started: bool,
		paths:   []string,
		texts:   []string,
		label:   string,
	}
	files_out_test: Files_Drag_Out_Test
}

// A tree drag moved to (x, y) (ui_files.odin, the drag's sources and the root they were captured
// in): outside the window, the system's drag starts with what it carries. True: the pointer is
// outside and the in-window drag is to end (whether or not the system's drag could start).
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
	if !files_drag_out_outside(x, y, w, h) do return false
	paths, skipped := files_drag_out_paths(root == core.files_root() ? root : "", sources, proc(p: string) -> bool {return core.settings_credential(p) || core.fs_credential_place(p)})
	if skipped > 0 do toast_show(fmt.tprintf("%d not dragged: credentials", skipped), err = true)
	if len(paths) == 0 do return true
	texts := make([]string, len(paths), context.temp_allocator)
	for p, i in paths do texts[i] = shell_quote(p)
	label := files_drag_out_label(paths)
	files_out.eat_release = true // set first: the release AppKit takes may still come
	when core.TEST_HOOKS {
		if testing {
			files_out_test.started, files_out_test.paths, files_out_test.texts, files_out_test.label = true, paths, texts, label
			return true
		}
	}
	platform_drag_out_begin(paths, texts, label)
	return true
}

// Every event, first in event() (main.odin): while a system drag of ours is on, nothing dropped
// on the window is taken (our own files back on the window); after one, releases go nowhere
// until the next press. True: taken.
files_drag_out_event :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .MOUSE_DOWN:
		files_out.eat_release = false
	case .MOUSE_UP:
		if files_out.eat_release {
			app.redraw = true
			return true
		}
	case .FILES_DROPPED:
		return platform_drag_out_active()
	}
	return false
}
