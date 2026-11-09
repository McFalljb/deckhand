package core

// The window's door over core.sock (docs/plans/background-core.md §5.3 "Window → core", §10.3
// M4-C): with a separate core (`deckhand-core serve`), the window is another process and the
// `ui` caller comes over the socket. Only a framed hello gets it, and only when every check holds,
// in this order, before the reply:
//   1. its token is run/window.token's (0600, written when the core starts: window_token_publish);
//   2. the peer read at accept (before any byte was read) is this user, and still that process;
//   3. its code has the window's designated requirement as our own signature gives it
//      (trust.peer_dr_check over WINDOW_IDS: under the self-signed identity, our certificate);
//   4. its version is not below the window floor (the newest window that attached to this core);
//   5. it does not descend from this core or its session holder (a tab's program is no window).
// Any other framed hello is refused: the framed wire is the window's only (M4-B's review).
// Ad hoc and self-signed builds stop accidents, not a determined process of the same user (§5.4).
//
// A framed connection leaves the line server (conn_handoff): the reader thread queues it here
// (window_arrived) and wakes the main thread, which attaches it (window_door_tick) as the
// window's link (window_link.odin). From then on the link owns it: socket_stop does not see it,
// so window_door_stop ends it at shutdown, and the transport re-reads the peer before every read
// (trust.peer_still). The window token is the core's for its whole run: nothing revokes it
// before the core exits, when the file goes.

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sys/posix"

import cw "../corewire"
import "../trust"

WINDOW_TOKEN_FILE :: "window.token"

// The identifiers a window's code may have (the unit tests set the test binary's own).
when TEST_HOOKS {
	window_peer_ids: []string = trust.WINDOW_IDS
} else {
	window_peer_ids :: trust.WINDOW_IDS
}

@(private = "file")
Window_Arrival :: struct {
	fd:       Sock_Fd,
	leftover: []u8, // heap
	peer:     trust.Peer,
	version:  string, // heap: the window's release version ("" for a development build)
}

@(private = "file")
door: struct {
	mu:         sync.Mutex,
	on:         bool, // a separate core's: framed hellos are looked at
	token:      [64]u8, // hex
	path:       string, // heap: run/window.token
	floor:      cw.Version, // the newest window version that attached (in memory: this core's run)
	holder_pid: i32, // the session holder's (main thread keeps it current)
	own_pid:    i32,
	arrived:    [dynamic]Window_Arrival,
}

// Writes run/window.token (a fresh token, 0600, replacing one from an earlier run) and opens the
// door. Main thread, at serve's start. False: the file could not be written.
window_token_publish :: proc(run_dir: string) -> bool {
	raw: [32]u8
	crypto.rand_bytes(raw[:])
	hex := hex32(raw)
	trust.wipe(raw[:])
	path := fmt.tprintf("%s/%s", run_dir, WINDOW_TOKEN_FILE)
	tmp := fmt.tprintf("%s.new", path)
	os.remove(tmp)
	fd := posix.open(strings.clone_to_cstring(tmp, context.temp_allocator), {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return false
	ok := posix.write(fd, raw_data(hex), len(hex)) == len(hex)
	posix.close(fd)
	if !ok || posix.rename(strings.clone_to_cstring(tmp, context.temp_allocator), strings.clone_to_cstring(path, context.temp_allocator)) != 0 {
		os.remove(tmp)
		return false
	}
	sync.guard(&door.mu)
	copy(door.token[:], hex)
	delete(door.path, runtime.heap_allocator())
	door.path = strings.clone(path, runtime.heap_allocator())
	door.own_pid = i32(posix.getpid())
	door.on = true
	socket_framed_handler = window_arrived
	return true
}

// The window's side: the token a running core wrote ("" = none, or not readable as one).
window_token_read :: proc(run_dir: string, allocator := context.temp_allocator) -> string {
	path := fmt.tprintf("%s/%s", run_dir, WINDOW_TOKEN_FILE)
	st: posix.stat_t
	cp := strings.clone_to_cstring(path, context.temp_allocator)
	if posix.lstat(cp, &st) != .OK || !posix.S_ISREG(st.st_mode) || st.st_uid != posix.getuid() do return ""
	if st.st_mode & {.IRGRP, .IWGRP, .IROTH, .IWOTH} != {} do return "" // not 0600: not one a core wrote
	b, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil || !hex64_ok(string(b)) do return ""
	return strings.clone(string(b), allocator)
}

// The window's checks, as facts (window_hello_refusal decides; table-tested).
Window_Hello :: struct {
	token_ok:     bool, // its token is the core's window token
	same_user:    bool, // trust.peer_allowed at accept
	still:        bool, // trust.peer_still: the process checked at accept sent the hello
	code:         trust.Decision, // trust.peer_dr_check over window_peer_ids
	floor:        cw.Floor, // its version against the window floor
	holder_child: bool, // it descends from this core or its session holder
}

// "" = the window may attach; else why not (in the order the checks run).
window_hello_refusal :: proc(h: Window_Hello) -> string {
	if !h.token_ok do return "framed mode is only for Deckhand's window (with the core's window token)"
	if !h.same_user do return "the window must run as this user"
	if !h.still do return "the window's process changed since it connected"
	if h.code != .Allow do return fmt.tprintf("the window's code is not Deckhand's (%v)", h.code)
	if h.floor != .Allow do return "This Deckhand is older than the one last used with these sessions"
	if h.holder_child do return "a program running in a Deckhand tab can't be its window"
	return ""
}

// The framed hello's checks (a connection's reader thread, before the reply). at_accept and tok:
// the peer as read at accept. version: the window's, for the floor (temp allocator).
window_hello_check :: proc(fd: Sock_Fd, at_accept: trust.Peer, tok: trust.Audit_Token, token: string) -> (why, version: string) {
	sync.lock(&door.mu)
	on, want, holder, own, floor := door.on, door.token, door.holder_pid, door.own_pid, door.floor
	sync.unlock(&door.mu)
	h: Window_Hello
	h.token_ok = on && hex64_equal(string(want[:]), token)
	h.same_user = trust.peer_allowed(.Adhoc, trust.own_uid(), at_accept) == .Allow
	h.still = trust.peer_still(at_accept, trust.peer_read(fd)) == .Allow
	h.code = .No_Code
	if h.token_ok && h.same_user && h.still {
		d, got := trust.peer_dr_check(tok, window_peer_ids)
		h.code, version = d, got.version
	}
	h.floor = cw.window_floor_check(floor, version)
	h.holder_child = pid_descends_from(at_accept.pid, {own, holder})
	return window_hello_refusal(h), version
}

// Whether pid's ancestors (itself included) hold one of these pids (0s skipped). At most 64 steps.
pid_descends_from :: proc(pid: i32, of: []i32) -> bool {
	p := pid
	for _ in 0 ..< 64 {
		if p <= 1 do return false
		for o in of do if o > 0 && p == o do return true
		p = pid_parent(p)
	}
	return false
}

// socket_framed_handler: a window passed its hello (a reader thread). It waits for the main thread.
@(private = "file")
window_arrived :: proc(fd: Sock_Fd, caller: Caller, leftover: []u8, peer: trust.Peer, version: string) {
	heap := runtime.heap_allocator()
	a := Window_Arrival{fd = fd, leftover = make([]u8, len(leftover), heap), peer = peer, version = strings.clone(version, heap)}
	copy(a.leftover, leftover)
	sync.lock(&door.mu)
	if !door.on {
		sync.unlock(&door.mu)
		sock_close(fd)
		delete(a.leftover, heap)
		delete(a.version, heap)
		return
	}
	if door.arrived == nil do door.arrived = make([dynamic]Window_Arrival, heap)
	append(&door.arrived, a)
	sync.unlock(&door.mu)
	if platform.wake != nil do platform.wake()
}

// Main thread, each turn of the core loop: windows that said their hello attach (the newest one
// stays), and the door learns the holder's pid.
window_door_tick :: proc() {
	sync.lock(&door.mu)
	door.holder_pid = hc.pid
	if len(door.arrived) == 0 {
		sync.unlock(&door.mu)
		return
	}
	got := door.arrived
	door.arrived = nil
	sync.unlock(&door.mu)
	heap := runtime.heap_allocator()
	for a, i in got {
		if i == len(got) - 1 && core_attach_window_sock(a.fd, a.leftover, a.peer) {
			sync.lock(&door.mu)
			door.floor = cw.window_floor_raise(door.floor, a.version)
			sync.unlock(&door.mu)
		} else do sock_close(a.fd)
		delete(a.leftover, heap)
		delete(a.version, heap)
	}
	delete(got)
}

// The core stops: no more windows; the attached one and any waiting are let go, and the token file
// goes. Main thread.
window_door_stop :: proc() {
	sync.lock(&door.mu)
	door.on = false
	got := door.arrived
	door.arrived = nil
	if door.path != "" do os.remove(door.path)
	sync.unlock(&door.mu)
	for a in got {
		sock_close(a.fd)
		delete(a.leftover, runtime.heap_allocator())
		delete(a.version, runtime.heap_allocator())
	}
	delete(got)
	if window_link_is_sock() do core_detach_window()
}

// ---- the window's side: the core it dials ----

// The identifiers a separate core's code may have (the unit tests' fake core sets its own).
when TEST_HOOKS {
	core_peer_ids: []string = trust.CORE_IDS
} else {
	core_peer_ids :: trust.CORE_IDS
}

// The window checks the core before it sends a byte (§5.3 B4): the peer of fd, read now, is this
// user and its code has the core's designated requirement (Deckhand Core.app's). "" = it may be
// talked to; peer: what transport reads compare with (trust.peer_still).
core_peer_check :: proc(fd: Sock_Fd) -> (peer: trust.Peer, why: string) {
	p, tok := trust.peer_read_token(fd)
	if d := trust.peer_allowed(.Adhoc, trust.own_uid(), p); d != .Allow do return p, fmt.tprintf("the process on core.sock is not ours (%v)", d)
	if d, got := trust.peer_dr_check(tok, core_peer_ids); d != .Allow {
		return p, fmt.tprintf("the process on core.sock is not Deckhand's core: its code: %v (identifier %q, status %d)", d, got.identifier, got.status)
	}
	return p, ""
}

// What the window says when a core's hello reply shows skew (§7.5; M4-E adds the handovers).
// "" = it works.
core_skew_message :: proc(s: cw.Skew) -> string {
	switch s {
	case .Ok, .Core_Older: return ""
	case .Core_Below_Min: return "Deckhand's background core is out of date: Quit Deckhand and Stop All Sessions, then open Deckhand again"
	case .Core_Newer_Generation: return "Update Deckhand: its background core is newer than this app"
	case .Core_Older_Generation: return "Deckhand's background core is older than this app: Quit Deckhand and Stop All Sessions, then open Deckhand again"
	}
	return ""
}

// Tests: the pids a window must not descend from (the test's client is its own process).
window_door_pids_for_test :: proc(own, holder: i32) {
	sync.guard(&door.mu)
	door.own_pid, door.holder_pid = own, holder
}
