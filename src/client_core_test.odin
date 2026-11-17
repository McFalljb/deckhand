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

// A separate core's path_changed (its own file command) reaches an idle window: the listings
// forget the path and a frame is asked for, so the Files tree reads it again even when the command
// sent this window no state delta (a control caller's file, changed = false).
@(test)
client_path_changed_redraws :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer posix.close(fds[1])
	saved, saved_redraw := client, app.redraw
	defer {
		client = saved
		app.redraw = saved_redraw
	}
	client = {}
	sock: cw.Sock_Transport
	cw.sock_open(&sock, fds[0])
	defer cw.sock_destroy(&sock)
	client.sock = &sock // a separate core's window
	app.redraw = false
	window_request_run({op = .Path_Changed, path = "/tmp/dh-path-changed/n.md"})
	testing.expect(t, app.redraw, "an idle window was not asked to draw the Files tree again")
	client.sock = nil
}

// A separate core's Changes action ended (path_changed, count 1: the checkout's root): this
// window's own list of that checkout is read again at once (now), as in process, not after its
// watcher's event and the debounce; another checkout's is left alone (#160).
@(test)
client_changes_action_reads_list_now :: proc(t: ^testing.T) {
	fds: [2]posix.FD
	testing.expect(t, posix.socketpair(.UNIX, .STREAM, .IP, &fds) == .OK)
	defer posix.close(fds[1])
	saved, saved_redraw, saved_repos := client, app.redraw, core.changes_repos
	defer {
		client = saved
		app.redraw = saved_redraw
		core.changes_repos = saved_repos
	}
	client = {}
	sock: cw.Sock_Transport
	cw.sock_open(&sock, fds[0])
	defer cw.sock_destroy(&sock)
	client.sock = &sock // a separate core's window
	a := core.Changes_Repo{root = "/tmp/dh-changes-a", loaded = true}
	b := core.Changes_Repo{root = "/tmp/dh-changes-b", loaded = true}
	core.changes_repos = make([dynamic]^core.Changes_Repo, context.temp_allocator)
	append(&core.changes_repos, &a, &b)
	window_request_run({op = .Path_Changed, path = "/tmp/dh-changes-a", count = 1})
	testing.expect(t, a.stale && a.now, "the action's checkout is not read again at once")
	testing.expect(t, !b.now, "another checkout is read at once too")
	b.stale = false
	window_request_run({op = .Path_Changed, path = "/tmp/dh-changes-b"}) // a file command's path: the debounce as before
	testing.expect(t, !b.now, "a plain path_changed reads the list at once")
	client.sock = nil
}
