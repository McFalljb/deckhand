#+build darwin
package main

// The system drag of Files rows out of the window (src/native/dragout_macos.m; files_drag_out.odin).

import "core:c"
import "core:strings"
import sapp "../vendor/sokol-odin/sokol/app"

foreign import pddragout {
	"../build/dh_dragout.a",
	"system:Cocoa.framework",
}

@(default_calling_convention = "c")
foreign pddragout {
	dh_drag_out_begin :: proc(window: rawptr, paths, texts: [^]cstring, n: c.int, label: cstring) -> c.int ---
	dh_drag_out_active :: proc() -> c.int ---
	dh_drag_out_mask :: proc(outside_app: c.int) -> c.int ---
	dh_drag_out_test_items :: proc(paths, texts: [^]cstring, n: c.int, out: [^]u8, cap: c.int) -> c.int ---
}

platform_drag_out_supported :: proc() -> bool {return true}
platform_drag_out_active :: proc() -> bool {return dh_drag_out_active() != 0}

// Starts the system drag (only while AppKit is handling the window's left-button drag). True: on.
platform_drag_out_begin :: proc(paths, texts: []string, label: string) -> bool {
	cp, ct := drag_out_cstrings(paths), drag_out_cstrings(texts)
	return dh_drag_out_begin(sapp.macos_get_window(), raw_data(cp), raw_data(ct), c.int(len(paths)), strings.clone_to_cstring(label, context.temp_allocator)) != 0
}

// What a drag of ours offers: inside Deckhand (false) or to another app (true). Copy = 1.
platform_drag_out_mask :: proc(outside_app: bool) -> int {return int(dh_drag_out_mask(outside_app ? 1 : 0))}

// Tests: the pasteboard items a drag of paths carries, read back ("<file URL>\t<text>\n" each).
platform_drag_out_test_items :: proc(paths, texts: []string) -> (string, bool) {
	cp, ct := drag_out_cstrings(paths), drag_out_cstrings(texts)
	buf := make([]u8, 1 << 16, context.temp_allocator)
	n := dh_drag_out_test_items(raw_data(cp), raw_data(ct), c.int(len(paths)), raw_data(buf), c.int(len(buf)))
	if n < 0 do return "", false
	return string(buf[:n]), true
}

@(private = "file")
drag_out_cstrings :: proc(s: []string) -> []cstring {
	out := make([]cstring, len(s), context.temp_allocator)
	for x, i in s do out[i] = strings.clone_to_cstring(x, context.temp_allocator)
	return out
}
