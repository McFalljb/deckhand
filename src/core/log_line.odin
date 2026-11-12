package core

// The core's log lines on stderr (<run>/core.log for a separate core, the window's stderr in
// process): each one starts with the time it was written, in UTC (#108), as the holder's do
// (src/holder log_line). One write per line, so threads' lines never interleave.
//
//   2026-11-12T17:30:01Z Deckhand: session holder: attached again; 3 running terminal(s) kept

import "core:fmt"
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
