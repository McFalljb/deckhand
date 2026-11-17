#+build darwin
package main

// The system drag of Files rows out of the window (src/native/dragout_macos.m; files_drag_out.odin).

import "core:c"
import "core:strings"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

foreign import pddragout {
	"../build/dh_dragout.a",
	"system:Cocoa.framework",
}

@(default_calling_convention = "c")
foreign pddragout {
	dh_drag_out_begin :: proc(window: rawptr, paths: [^]cstring, n: c.int, text, label: cstring) -> c.int ---
	dh_drag_out_active :: proc() -> c.int ---
	dh_drag_out_synthetic :: proc() -> c.int ---
	dh_drag_out_mask :: proc(outside_app: c.int) -> c.int ---
}

platform_drag_out_supported :: proc() -> bool {return true}
platform_drag_out_active :: proc() -> bool {return dh_drag_out_active() != 0}
// The release being delivered is our own (sent to let go of sokol's button after a drag out).
platform_drag_out_synthetic :: proc() -> bool {return dh_drag_out_synthetic() != 0}

// Starts the system drag (only while AppKit is handling the window's left-button drag). True: on.
platform_drag_out_begin :: proc(paths: []string, text, label: string) -> bool {
	cp := drag_out_cstrings(paths)
	return dh_drag_out_begin(sapp.macos_get_window(), raw_data(cp), c.int(len(paths)), strings.clone_to_cstring(text, context.temp_allocator), strings.clone_to_cstring(label, context.temp_allocator)) != 0
}

// What a drag of ours offers: inside Deckhand (false) or to another app (true). Copy = 1.
platform_drag_out_mask :: proc(outside_app: bool) -> int {return int(dh_drag_out_mask(outside_app ? 1 : 0))}

when core.TEST_HOOKS {
	// src/native/dragout_test_macos.m: linked only into builds with test hooks
	@(default_calling_convention = "c")
	foreign pddragout {
		dh_drag_out_test_items :: proc(paths: [^]cstring, n: c.int, text: cstring, out: [^]u8, cap: c.int) -> c.int ---
	}

	// Tests: the pasteboard items a drag of paths carries, read back ("<file URL>\t<text>\n" each).
	platform_drag_out_test_items :: proc(paths: []string, text: string) -> (string, bool) {
		cp := drag_out_cstrings(paths)
		buf := make([]u8, 1 << 16, context.temp_allocator)
		n := dh_drag_out_test_items(raw_data(cp), c.int(len(paths)), strings.clone_to_cstring(text, context.temp_allocator), raw_data(buf), c.int(len(buf)))
		if n < 0 do return "", false
		return string(buf[:n]), true
	}
}

@(private = "file")
drag_out_cstrings :: proc(s: []string) -> []cstring {
	out := make([]cstring, len(s), context.temp_allocator)
	for x, i in s do out[i] = strings.clone_to_cstring(x, context.temp_allocator)
	return out
}
