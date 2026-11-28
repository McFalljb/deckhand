package core

import "core:strings"
import "core:testing"

import cw "../corewire"

// The core's line for a link that ended names the link (window, browser and its device, hub and
// its machine), its pid or device, who closed it and why.
@(test)
link_end_lines :: proc(t: ^testing.T) {
	win := link_who_text(false, false, "", "", 4242)
	testing.expectf(t, strings.contains(win, "window") && strings.contains(win, "pid 4242"), "%q", win)
	web := link_who_text(false, true, "Phone", "0123456789ab", 0)
	testing.expectf(t, strings.contains(web, "browser") && strings.contains(web, "Phone") && strings.contains(web, "0123456789ab"), "%q", web)
	hub := link_who_text(true, false, "mini", "", 77)
	testing.expectf(t, strings.contains(hub, "hub") && strings.contains(hub, "mini") && strings.contains(hub, "pid 77"), "%q", hub)
	peer := link_end_text(win, .Peer_Closed)
	testing.expectf(t, strings.contains(peer, "pid 4242") && strings.contains(peer, "closed by the other side"), "%q", peer)
	changed := link_end_text(win, .Peer_Changed, "now pid 99")
	testing.expectf(t, strings.contains(changed, "closed by this side") && strings.contains(changed, "now pid 99"), "%q", changed)
	testing.expect_value(t, cw.sock_reason_text(.Io_Error), "a read or write failed")
}
