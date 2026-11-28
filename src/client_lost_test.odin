package main

import "core:strings"
import "core:sys/posix"
import "core:testing"

import "core"
import cw "corewire"

// While the core's link is lost (reconnecting), a ui command is refused with a note, not sent, and
// not queued for later; ⌘S still saves locally (lost_core_save).
@(test)
lost_command_refused :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect_value(t, posix.socketpair(.UNIX, .STREAM, posix.Protocol(0), &fds), posix.result.OK)
	defer posix.close(fds[1])
	tr: cw.Sock_Transport
	cw.sock_open(&tr, fds[0])
	defer cw.sock_destroy(&tr)
	saved_sock, saved_attached, saved_lost := client.sock, client.attached, client.lost
	defer client.sock, client.attached, client.lost = saved_sock, saved_attached, saved_lost
	client.sock, client.attached, client.lost = &tr, true, true
	toast_clear()
	ui_do(core.Rename_Project{project_id = 1, name = "x"})
	testing.expectf(t, strings.contains(toast.text, "Not connected to Deckhand's background core"), "toast: %q", toast.text)
	cw.sock_flush(&tr)
	posix.fcntl(fds[1], .SETFL, posix.O_NONBLOCK)
	buf: [256]u8
	n := posix.read(fds[1], raw_data(buf[:]), len(buf))
	testing.expectf(t, n <= 0, "nothing reached the core's end: %d bytes", n)
	toast_clear()
}
