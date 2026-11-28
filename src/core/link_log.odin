package core

// What the core's log says about the link to its window (window_link.odin): which link it was,
// and how it ended. Never a token: a link is named by its kind, its peer's pid, and for a browser
// its device id (12 random hex digits, shown in Settings) and the name it gave itself.

import "core:fmt"

import cw "../corewire"
import "../trust"

// "the window (pid 4242)", "a browser over web access, \"Phone\" (device 0123456789ab)", "the
// hub link from \"mini\" (pid 77)". pid 0: not known (in process).
link_who_text :: proc(hub, web: bool, from, device: string, pid: i32) -> string {
	if web do return fmt.tprintf("a browser over web access, %q (device %s)", from, device != "" ? device : "?")
	at := pid > 0 ? fmt.tprintf(" (pid %d)", pid) : " (in process)"
	if hub do return fmt.tprintf("the hub link from %q%s", from, at)
	return fmt.tprintf("the window%s", at)
}

// The log line for a link that ended: who it was, who closed it and why.
link_end_text :: proc(who: string, reason: cw.Close_Reason, detail := "") -> string {
	more := detail != "" ? fmt.tprintf(" (%s)", detail) : ""
	return fmt.tprintf("Deckhand: the link to %s ended: %s%s", who, cw.sock_reason_text(reason), more)
}

// What the per-read peer check (design §5.3) saw instead of the process checked at connect.
peer_change_text :: proc(at_connect, now: trust.Peer) -> string {
	if !now.ok do return fmt.tprintf("connected to pid %d; now no process: the last one to use the other end has exited", at_connect.pid)
	if now.pid != at_connect.pid do return fmt.tprintf("connected to pid %d; now pid %d", at_connect.pid, now.pid)
	if now.pidversion != at_connect.pidversion do return fmt.tprintf("pid %d ran another program since", now.pid)
	return fmt.tprintf("pid %d, now another user", now.pid)
}
