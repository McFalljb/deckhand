package main

// The window's own log: <run>/window.log, beside the core's core.log. The app's stderr is
// /dev/null when it starts from the Dock or Finder, so what the window says about its core (a
// lost connection and the transport's reason, each reconnect and its result, a give-up, a
// takeover) and about its file watcher would otherwise go nowhere. Lines are stamped and redacted
// as core.log_file_write does (core/log_line.odin), and still go to stderr too (a terminal run, a
// scene's log). Opened at init with a separate core (init_separate); before that, or without a
// run dir, lines go to stderr only.

import "core:fmt"
import "core:strings"

import "core"

WINDOW_LOG :: "window.log"

window_log: core.Log_File

// Opens <run>/window.log (the run dir core.sock is in). Main thread, at init.
window_log_open :: proc() {
	run, why := core.sock_runtime_dir_why(context.temp_allocator)
	if why != "" do return
	if !core.log_file_open(&window_log, fmt.tprintf("%s/%s", run, WINDOW_LOG)) do fmt.eprintln("Deckhand: cannot open", WINDOW_LOG, "in", run)
}

// Where the window's log is ("" = not open).
window_log_path :: proc() -> string {return window_log.path}

// A line for the window's log (and stderr), as fmt.println joins its args. "Deckhand: " in front.
wlog :: proc(args: ..any) {
	text := fmt.tprint(..args, sep = " ")
	if !strings.has_prefix(text, "Deckhand") do text = fmt.tprintf("Deckhand: %s", text)
	line := core.log_file_write(&window_log, text)
	if line != "" do fmt.eprint(line)
	else do fmt.eprintln(core.redact_secrets(text))
}
