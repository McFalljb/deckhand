package main

// The window's side of a separate core (client_core.odin): a command's result is waited for at
// most CLIENT_WAIT, then it shows as pending and the late one is dropped (design Q9).

import "core:sys/posix"
import "core:testing"
import "core:time"
import "base:runtime"
import "core"
import cw "corewire"

@(test)
client_wait_is_bounded :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer posix.close(fds[1])
	heap := runtime.heap_allocator()
	saved := client
	defer client = saved
	client = {}
	client.results = make(map[string]core.Result, heap)
	client.abandoned = make(map[string]bool, heap)
	defer delete(client.results)
	defer delete(client.abandoned)
	sock: cw.Sock_Transport
	cw.sock_open(&sock, fds[0])
	defer cw.sock_destroy(&sock)
	client.sock = &sock
	gave0 := client_wait_gave_up
	start := time.tick_now()
	r := client_wait("c1") // a core that never answers
	took := time.tick_since(start)
	testing.expect(t, r.ok && r.pending, "shows as pending")
	testing.expectf(t, took >= CLIENT_WAIT && took < CLIENT_WAIT + 200 * time.Millisecond, "waited %v", took)
	testing.expect_value(t, client_wait_gave_up, gave0 + 1)
	testing.expect(t, "c1" in client.abandoned, "the late result will be dropped")
	for k in client.abandoned do delete(k, heap)
	client.sock = nil
}
