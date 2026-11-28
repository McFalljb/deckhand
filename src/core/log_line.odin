package core

// The core's log lines on stderr (<run>/core.log for a separate core, the window's stderr in
// process): each one starts with the time it was written, in UTC (#108), as the holder's do
// (src/holder log_line). One write per line, so threads' lines never interleave.
//
//   2026-11-12T17:30:01Z Deckhand: session holder: attached again; 3 running terminal(s) kept

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// "YYYY-MM-DDTHH:MM:SSZ" for t (temp).
log_stamp :: proc(t: time.Time) -> string {
	y, mo, d := time.date(t)
	h, mi, s := time.clock(t)
	return fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02dZ", y, int(mo), d, h, mi, s)
}

// fmt.eprintln with the time in front.
log_ln :: proc(args: ..any, sep := " ") {
	fmt.eprintf("%s %s\n", log_stamp(time.now()), fmt.tprint(..args, sep = sep))
}

// fmt.eprintfln with the time in front.
log_fln :: proc(format: string, args: ..any) {
	fmt.eprintf("%s %s\n", log_stamp(time.now()), fmt.tprintf(format, ..args))
}

// fmt.eprintf with the time in front (format ends the line itself).
log_f :: proc(format: string, args: ..any) {
	fmt.eprintf("%s %s", log_stamp(time.now()), fmt.tprintf(format, ..args))
}

// ---- a log file of its own (the window's run/window.log: the app's stderr is /dev/null) ----
//
// Each line is stamped as log_ln stamps it and goes through redact_secrets (jobs_note.odin: the
// redaction the job notes use), so a key-, token- or password-shaped string never lands on disk.
// The file is 0600, opened once and kept open (a process out of descriptors still logs), and
// rotated past its cap into <path>.1: at most two files.

LOG_FILE_CAP :: 1024 * 1024

Log_File :: struct {
	path: string, // heap
	f:    ^os.File,
	size: i64,
	cap:  i64,
}

// Opens path for appending (made 0600). False: it could not be opened (lines are then dropped).
log_file_open :: proc(l: ^Log_File, path: string, cap: i64 = LOG_FILE_CAP) -> bool {
	log_file_close(l)
	l.path = strings.clone(path, runtime.heap_allocator())
	l.cap = cap
	return log_file_reopen(l)
}

log_file_close :: proc(l: ^Log_File) {
	if l.f != nil do os.close(l.f)
	l.f = nil
	delete(l.path, runtime.heap_allocator())
	l.path = ""
}

@(private = "file")
log_file_reopen :: proc(l: ^Log_File) -> bool {
	f, err := os.open(l.path, {.Write, .Create, .Append}, {.Read_User, .Write_User})
	if err != nil do return false
	l.f = f
	l.size, _ = os.file_size(f)
	return true
}

// One line (redacted, stamped) at the end of the file; the file rotates first when it would pass
// its cap. Returns the line as written (temp), "" when the file is not open.
log_file_write :: proc(l: ^Log_File, text: string) -> string {
	if l.f == nil do return ""
	line := fmt.tprintf("%s %s\n", log_stamp(time.now()), redact_secrets(text))
	if l.size > 0 && l.size + i64(len(line)) > l.cap {
		os.close(l.f)
		l.f = nil
		old := fmt.tprintf("%s.1", l.path)
		os.remove(old)
		os.rename(l.path, old)
		if !log_file_reopen(l) do return ""
	}
	os.write_string(l.f, line)
	l.size += i64(len(line))
	return line
}
