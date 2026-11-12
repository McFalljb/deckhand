package core

// What commands may ask of the window/OS layer. State, commands and services
// never call sokol or OS UI APIs; main.odin fills these in at startup (tests
// leave them nil or set fakes). A headless core would provide its own.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

Platform :: struct {
	quit:           proc(), // the user confirmed: close the app
	wake:           proc(), // any thread: get the main thread to drain the inbox soon
	run_later:      proc(p: proc()), // main thread: runs p soon from the main run loop, outside any event or frame callback
	notify:         proc(title, body: string), // an OS notification (the agent, while the window is in the background)
	notify_front:   proc(title, body: string), // one that macOS shows also while Deckhand is in front (a bell kind whose macOS says always; nil: notify)
	trash:          proc(path: string) -> bool, // moves path to the Trash; nil or false: not moved
	activity:       proc(on: bool), // holds off App Nap while on (activity_hold: jobs, recent output); nil: nothing
	// main thread: calls fire every `every` from the main run loop, outside sokol's callbacks, also
	// while no frames run (hidden, minimised, App Nap); core_loop.odin decides what it does. nil:
	// nothing (unit tests: frames, or the tests themselves, tick the core)
	core_timer:     proc(every: time.Duration, fire: proc()),
}
// What was the window's here (the clipboard, links, Reveal in Finder, the folder picker, the
// appearance, whether it has the keyboard) is the window's own (src/win_os.odin): the core asks
// with a window.request (window_hooks.odin).

platform: Platform

// Why App Nap is held off: running jobs (jobs.odin), a terminal's output in the last 2 s
// (core_loop.odin, Q11).
Activity_Reason :: enum {
	Jobs,
	Output,
}
activity_reasons: bit_set[Activity_Reason]

// Main thread: reason r holds App Nap off (on) or not; platform.activity hears only when the
// answer for all of them changes.
activity_hold :: proc(r: Activity_Reason, on: bool) {
	was := activity_reasons != {}
	if on do activity_reasons += {r}
	else do activity_reasons -= {r}
	now := activity_reasons != {}
	if now != was && platform.activity != nil do platform.activity(now)
}

// Where Deckhand keeps its own files (command log; later the saved
// workspace). DECKHAND_DATA_DIR overrides.
data_dir :: proc(allocator := context.allocator) -> string {
	if d := hook_env(.Data_Dir, allocator); d != "" do return d
	return data_dir_under(data_home(TEST_HOOKS, context.temp_allocator), allocator)
}

// The data dir under home; "" when home is not an absolute path (never one relative to the cwd:
// the launch then refuses to start, main.odin). The rename (0.2.0) reads both names:
// ~/Library/Application Support/Deckhand when it is there (or neither is: a new install), else
// the old ~/Library/Application Support/pi-desk, where every install up to 0.1.6 keeps its data.
// Nothing is moved yet (0.2.1 moves it, with a link back), so a downgrade still finds it.
data_dir_under :: proc(home: string, allocator := context.allocator) -> string {
	if !strings.has_prefix(home, "/") do return ""
	new, old := data_dir_names(home, context.temp_allocator)
	return strings.clone(data_dir_pick(new, old), allocator)
}

// The data dir's new and old place under home (temp allocator by default).
data_dir_names :: proc(home: string, allocator := context.temp_allocator) -> (new, old: string) {
	when ODIN_OS == .Darwin {
		new, _ = filepath.join({home, "Library", "Application Support", "Deckhand"}, allocator)
		old, _ = filepath.join({home, "Library", "Application Support", "pi-desk"}, allocator)
	} else {
		// Linux (§8.4): ~/.local/share/deckhand, never $XDG_DATA_HOME (an environment doesn't move
		// the data dir: data_home). pi-desk never ran there, so the old name is never a folder.
		new, _ = filepath.join({home, ".local", "share", "deckhand"}, allocator)
		old, _ = filepath.join({home, ".local", "share", "pi-desk"}, allocator)
	}
	return
}

// What data_dir_pick last said about its choice ("" = nothing to say; tests).
data_dir_note: string

// new when it is a folder or old is not one; else old. A link counts as what it points to. Both
// there (a dev copy, a downgrade, or 0.2.1 moved it and the link came back as a folder): old
// while a session holder answers under it (its held sessions must never be orphaned), else new;
// said once on stderr either way.
data_dir_pick :: proc(new, old: string) -> string {
	if !os.is_dir(old) do return new
	if !os.is_dir(new) do return old
	pick, note := new, fmt.tprintf("Deckhand: both %s and %s exist: using %s", new, old, new)
	if data_dir_holder_alive(old) {
		pick, note = old, fmt.tprintf("Deckhand: both %s and %s exist: using %s, where a session holder still runs", new, old, old)
	}
	if note != data_dir_note {
		delete(data_dir_note, runtime.heap_allocator())
		data_dir_note = strings.clone(note, runtime.heap_allocator())
		log_ln(note)
	}
	return pick
}

// Whether a holder (or a running Deckhand's core) answers on a socket in <dir>/run.
data_dir_holder_alive :: proc(dir: string) -> bool {
	run := fmt.tprintf("%s/run", dir)
	files, err := os.read_all_directory_by_path(run, context.temp_allocator)
	if err != nil do return false
	for f in files {
		if !strings.has_suffix(f.name, ".sock") || !(strings.has_prefix(f.name, "holder-") || f.name == "core.sock") do continue
		if fd, ok := sock_connect(f.fullpath); ok {
			sock_close(fd)
			return true
		}
	}
	return false
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
