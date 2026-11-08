package main

// What commands may ask of the window/OS layer. State, commands and services
// never call sokol or OS UI APIs; main.odin fills these in at startup (tests
// leave them nil or set fakes). A headless core would provide its own.

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"

Platform :: struct {
	set_clipboard:  proc(text: string),
	get_clipboard:  proc() -> string, // what a paste inserts (clipboard_text)
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
	// a secret (Copy a control token): onto the clipboard marked concealed and transient
	// (nspasteboard.org: clipboard managers neither show nor keep it); returns the change count
	// after it, for clear_clipboard_if. nil: set_clipboard (tests, test mode's own pasteboard)
	set_clipboard_secret: proc(text: string) -> int,
	clear_clipboard_if:   proc(count: int), // clears it if it still holds what that count put there
}

platform: Platform

// What a paste inserts: the system clipboard (a script's own pasteboard under autotest); "" with
// no platform (unit tests).
clipboard_text :: proc() -> string {
	return platform.get_clipboard != nil ? platform.get_clipboard() : ""
}

// Where pi-desk keeps its own files (command log; later the saved
// workspace). PI_DESK_DATA_DIR overrides.
data_dir :: proc(allocator := context.allocator) -> string {
	if d := hook_env(.Data_Dir, allocator); d != "" do return d
	return data_dir_under(data_home(TEST_HOOKS, context.temp_allocator), allocator)
}

// The data dir under home; "" when home is not an absolute path (never one relative to the cwd:
// the launch then refuses to start, main.odin).
data_dir_under :: proc(home: string, allocator := context.allocator) -> string {
	if !strings.has_prefix(home, "/") do return ""
	when ODIN_OS == .Darwin {
		p, _ := filepath.join({home, "Library", "Application Support", "pi-desk"}, allocator)
	} else {
		base := os.get_env("XDG_DATA_HOME", context.temp_allocator)
		if !strings.has_prefix(base, "/") do base, _ = filepath.join({home, ".local", "share"}, context.temp_allocator)
		p, _ := filepath.join({base, "pi-desk"}, allocator)
	}
	return p
}

// The home the data dir lives under. A release build: the account's (the user database), never
// $HOME, so an environment can't move the data dir, the runtime socket, tokens.json or the holder
// (background-core.md §5.3, "A genuine binary under attacker config"). Test and development
// builds: $HOME (scenes run with a fake one).
data_home :: proc(hooks: bool, allocator := context.temp_allocator) -> string {
	if hooks do return os.get_env("HOME", allocator)
	return account_home(allocator)
}

// The home directory of the real uid's account (getpwuid_r), or "" when there is none.
account_home :: proc(allocator := context.temp_allocator) -> string {
	return account_home_with(proc(buf: []u8) -> (dir: string, err: posix.Errno) {
		pw: posix.passwd
		res: ^posix.passwd
		err = posix.getpwuid_r(posix.getuid(), &pw, raw_data(buf), len(buf), &res)
		if err != .NONE || res == nil || pw.pw_dir == nil do return "", err
		return string(pw.pw_dir), .NONE
	}, allocator)
}

// lookup with a buffer grown on ERANGE (up to 1 MiB); its dir, cloned, or "".
account_home_with :: proc(lookup: proc(buf: []u8) -> (string, posix.Errno), allocator := context.temp_allocator) -> string {
	for size := 4096; size <= 1 << 20; size *= 2 {
		buf := make([]u8, size, context.temp_allocator)
		dir, err := lookup(buf)
		if err == .ERANGE do continue
		if err != .NONE do return ""
		return strings.clone(dir, allocator)
	}
	return ""
}
