package core

// What the core's log says about the link to its window (window_link.odin): which link it was,
// and how it ended. Never a token: a link is named by its kind, its peer's pid, and for a browser
// its device id (12 random hex digits, shown in Settings) and the name it gave itself.

import cw "../corewire"

// "the window (pid 4242)", "a browser over web access, \"Phone\" (device 0123456789ab)", "the
// hub link from \"mini\" (pid 77)". pid 0: not known (in process).
link_who_text :: proc(hub, web: bool, from, device: string, pid: i32) -> string {return ""}

// The log line for a link that ended: who it was, who closed it and why.
link_end_text :: proc(who: string, reason: cw.Close_Reason, detail := "") -> string {return ""}
