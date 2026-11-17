package main

// A Finder drag hovering the window (src/native/platform_macos.m, dh_mac_watch_file_drag): the
// Files tree shows where a drop would copy to (files_finder_hover, ui_files_drops.odin).

import "core:c"
import "core"
import sapp "../vendor/sokol-odin/sokol/app"

foreign import pdplatform_drag "../build/dh_platform.a"

@(default_calling_convention = "c")
foreign pdplatform_drag {
	dh_mac_watch_file_drag :: proc(cb: proc "c" (x, y: f32, on: c.int)) ---
}

// After the window is set up (main.odin's init).
finder_drag_watch :: proc() {
	dh_mac_watch_file_drag(proc "c" (x, y: f32, on: c.int) {
		context = core.app_context
		// the window's points to framebuffer px, as sokol reads a drop's place
		s := sapp.dpi_scale()
		files_finder_hover(x * s, y * s, on != 0)
	})
}
