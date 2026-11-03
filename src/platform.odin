package main

// What commands may ask of the window/OS layer. State, commands and services
// never call sokol or OS UI APIs; main.odin fills these in at startup (tests
// leave them nil or set fakes). A headless core would provide its own.

import "core:os"
import "core:path/filepath"

Platform :: struct {
	set_clipboard:  proc(text: string),
	quit:           proc(), // the user confirmed: close the app
	wake:           proc(), // any thread: get the main thread to drain the inbox soon
	pick_folder:    proc() -> string, // asks the user for a folder (modal); "" = cancelled
	run_later:      proc(p: proc()), // main thread: runs p soon from the main run loop, outside any event or frame callback
	set_appearance: proc(mode: Appearance), // the window's own appearance (title bar, folder picker): system = follow the OS
	reveal:         proc(path: string), // shows path in the file manager
	notify:         proc(title, body: string), // an OS notification (the agent, while the window is in the background)
	window_active:  proc() -> bool, // the window has the keyboard
	left_button:    proc() -> bool, // the left mouse button is down now (nil: assume it is)
	open_url:       proc(url: string) -> bool, // opens a web or mail link with the user's default app (Markdown and terminal links); false: not opened
	// the system clipboard's change count (browser_act.odin: a page changing it during an agent's
	// input is told to the user); nothing of its contents is read
	clipboard_count: proc() -> int,
}

platform: Platform

// Where pi-desk keeps its own files (command log; later the saved
// workspace). PI_DESK_DATA_DIR overrides.
data_dir :: proc(allocator := context.allocator) -> string {
	if d := os.get_env("PI_DESK_DATA_DIR", allocator); d != "" do return d
	home := os.get_env("HOME", context.temp_allocator)
	when ODIN_OS == .Darwin {
		p, _ := filepath.join({home, "Library", "Application Support", "pi-desk"}, allocator)
	} else {
		base := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if base == "" do base, _ = filepath.join({home, ".local", "share"}, context.temp_allocator)
		p, _ := filepath.join({base, "pi-desk"}, allocator)
	}
	return p
}
