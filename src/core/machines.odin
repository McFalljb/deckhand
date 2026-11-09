package core

// Other machines over SSH (docs/plans/background-core.md §8, §10.4 M6-A): the registry, the link
// to each machine's core and its status. Behind Settings › Experimental › Machines over SSH
// (remote_machines_default_on, off until M6-F). Only a separate core (deckhand-core-serve serve)
// runs links.
//
// The registry is <data>/machines.json (0600): {"next":N,"machines":[{no, name, target, os, arch,
// core_path, via?}]}. Numbers come from `next`, 1-8191, never reused (M6-B packs them into ids).
// machine_add, machine_remove and machine_connect are the user's only (who = .User); `via` (a
// command run in place of `ssh … connect`) is taken only in development and test builds.
//
// The link: the user's own `ssh` (their ~/.ssh/config: the target is an alias or user@host, never
// edited), run with argv only, never through a local shell:
//   ssh -S <run>/ssh-<n>.ctl -o ControlMaster=auto -o ControlPersist=600 -o BatchMode=yes
//       -o Compression=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=4 -- <target>
//       '"$HOME/<core path>" connect --from <this Mac>'
// on a socketpair: its stdin and stdout are one end, the transport (src/corewire) the other; its
// stderr is a pipe, read for why it failed. The remote command is one of two constant paths plus
// this Mac's name in [A-Za-z0-9._-] (machine_from_name), so nothing typed reaches the remote
// shell. A machine whose OS is not known yet is asked first (`uname -sm`, the same ssh).
// `deckhand-core-serve connect` on the other end says the hub hello (window_sock.odin) and copies
// bytes; its hello reply is the first line on the link, read here through skew_check.
//
// Caps from the first byte: the remote core treats the hub as its window, so it sends what a
// window would act on. Every window.request (clipboard, open_url, notify, reveal, pick_folder…)
// and confirmation.parked from a hub link is dropped here, unread, and never acted on (§8.3).
// M6-B reads its state; nothing else is read yet.
//
// Reconnects back off: 1 s, doubling to 60 s, back to 1 s after a minute up. A link the other
// machine's own window took back (hub.taken) waits for the user's Take back (machine_connect).

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

import cw "../corewire"
import jg "../jsonguard"

// Settings › Experimental › Machines over SSH: off by default until M6-F flips it (one line).
remote_machines_default_on := false

Set_Remote_Machines :: struct {
	on: bool,
}
// Adds a machine: name (what Deckhand calls it), target (an ~/.ssh/config alias or user@host);
// via: a development or test build's command in place of `ssh … connect`. User-only.
Machine_Add :: struct {
	name, target, via: string,
}
Machine_Remove :: struct {
	no: u64,
}
// Connect now: Take back from that machine's window, or retry without waiting. User-only.
Machine_Connect :: struct {
	no: u64,
}

Machine_Status :: enum u8 {
	Connecting,
	Online,
	Offline,
	Needs_Login, // ssh wanted a password, a host key or 2FA (BatchMode): Log in… (M6-B)
	Needs_Update, // its core is below CORE_MIN or another generation
	Not_Installed, // no core at its path
	Taken, // that machine's own window (or another hub) took it back
}

// A machine as State's `machines` section carries it (Settings › Machines).
Machine_View :: struct {
	no:      u64,
	name:    string,
	target:  string,
	status:  Machine_Status,
	version: string, // its core's release version ("" = a development build, or not known)
	os:      string, // "darwin", "linux" ("" = not known yet)
	arch:    string,
	error:   string, // why it is not online
}

// One registry entry (machines.json).
Machine :: struct {
	no:        u64,
	name:      string,
	target:    string,
	os:        string,
	arch:      string,
	core_path: string, // "~/…" (MACHINE_CORE_PATHS), from os
	via:       string,
}

MACHINES_FILE :: "machines.json"
MACHINE_NO_MAX :: 8191
MACHINE_CTL_MAX :: 86 // sun_path's 104, less ssh's ".<16 random>" temporary name and the NUL
MACHINE_BACKOFF_MIN :: time.Second
MACHINE_BACKOFF_MAX :: 60 * time.Second
MACHINE_UP_RESET :: 60 * time.Second // up this long: the next drop waits MACHINE_BACKOFF_MIN again
MACHINE_HELLO_WAIT :: 30 * time.Second // connect may launch a core (15 s) first
MACHINE_STDERR_MAX :: 4096

// Where a machine's core is, by its OS (its own data dir's core/current, §8.4).
MACHINE_CORE_PATHS := [?][2]string {
	{"darwin", "~/Library/Application Support/Deckhand/core/current/Deckhand Core.app/Contents/MacOS/deckhand-core-serve"},
	{"linux", "~/.local/share/deckhand/core/current/deckhand-core-serve"},
}

machine_core_path_for :: proc(os_name: string) -> string {
	for p in MACHINE_CORE_PATHS do if p[0] == os_name do return p[1]
	return ""
}

// ---- names ----

// Why a machine's name cannot be used ("" = it can).
machine_name_error :: proc(name: string) -> string {
	if strings.trim_space(name) == "" do return "a machine needs a name"
	if len(name) > 64 do return "a machine's name has at most 64 bytes"
	for r in name do if r < 0x20 || r == 0x7f do return "a machine's name cannot hold control characters"
	return ""
}

// Why an ssh target cannot be used ("" = it can): an ~/.ssh/config alias, host, user@host or
// user@host:port-free form, in [A-Za-z0-9._@:-], never starting with '-' (an ssh option).
machine_target_error :: proc(target: string) -> string {
	if target == "" do return "a machine needs a target (an ~/.ssh/config alias or user@host)"
	if len(target) > 255 do return "the target is too long"
	if target[0] == '-' do return "a target cannot start with -"
	for c in transmute([]u8)target {
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-' || c == '@' || c == ':'
		if !ok do return "a target holds only letters, digits and . _ - @ :"
	}
	return ""
}

// This Mac's name as the hub hello says it (Viewed from <machine>): the host name without
// ".local", in [A-Za-z0-9._-], at most 64 bytes (it rides in the remote command's argv).
machine_from_name :: proc(host: string) -> string {
	h := strings.trim_suffix(host, ".local")
	b := strings.builder_make(context.temp_allocator)
	for c in transmute([]u8)h {
		if strings.builder_len(b) >= 64 do break
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
		strings.write_byte(&b, ok ? c : '-')
	}
	s := strings.to_string(b)
	return s == "" ? "mac" : s
}

// ---- the ssh argv ----

machine_ctl_path :: proc(run: string, no: u64) -> string {
	return fmt.tprintf("%s/ssh-%d.ctl", strings.trim_right(run, "/"), no)
}

// What runs for machine m: `ssh … <target> 'uname -sm'` (probe) or `ssh … connect`, or its via
// command (development and test builds only). argv[0] is looked up on PATH. Temp allocator.
machine_argv :: proc(m: Machine, run, from: string, probe := false, test_build := TEST_HOOKS) -> (argv: []string, why: string) {
	out := make([dynamic]string, context.temp_allocator)
	if m.via != "" {
		if !test_build do return nil, "via is only for development and test builds"
		for f in strings.fields(m.via, context.temp_allocator) do append(&out, f)
		if len(out) == 0 do return nil, "via is empty"
		append(&out, "--from", machine_from_name(from))
		return out[:], ""
	}
	if w := machine_target_error(m.target); w != "" do return nil, w
	ctl := machine_ctl_path(run, m.no)
	if len(ctl) > MACHINE_CTL_MAX do return nil, fmt.tprintf("ssh's control socket %s is longer than %d bytes", ctl, MACHINE_CTL_MAX)
	remote: string
	if probe {
		remote = "uname -sm"
	} else {
		want := machine_core_path_for(m.os)
		if want == "" || m.core_path != want do return nil, "this machine's core path is not one Deckhand knows"
		remote = fmt.tprintf(`"$HOME/%s" connect --from %s`, want[2:], machine_from_name(from))
	}
	append(&out, "ssh", "-S", ctl, "-o", "ControlMaster=auto", "-o", "ControlPersist=600", "-o", "BatchMode=yes", "-o", "Compression=yes", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "--", m.target, remote)
	return out[:], ""
}

// `uname -sm`'s answer as Odin names it (the hello reply's machine{os, arch}).
machine_uname_parse :: proc(text: string) -> (os_name, arch: string, ok: bool) {
	f := strings.fields(strings.trim_space(text), context.temp_allocator)
	if len(f) != 2 do return "", "", false
	switch f[0] {
	case "Darwin": os_name = "darwin"
	case "Linux":  os_name = "linux"
	case:          return "", "", false
	}
	switch f[1] {
	case "arm64", "aarch64": arch = "arm64"
	case "x86_64", "amd64":  arch = "amd64"
	case:                    return "", "", false
	}
	return os_name, arch, true
}

// ---- the status table ----

// What one attempt came to.
Machine_Outcome :: struct {
	replied:   bool, // a hello reply came
	ok:        bool, // ...and it said ok
	error:     string, // its error
	skew:      cw.Skew,
	exited:    bool, // the process ended (before a reply)
	exit_code: int,
	stderr:    string,
}

machine_status_of :: proc(o: Machine_Outcome) -> (s: Machine_Status, why: string) {
	if o.replied {
		if !o.ok do return .Offline, o.error
		switch o.skew {
		case .Ok, .Core_Older:      return .Online, ""
		case .Core_Below_Min:       return .Needs_Update, "its core is older than this Mac's can work with"
		case .Core_Older_Generation: return .Needs_Update, "its core is from an older generation"
		case .Core_Newer_Generation: return .Needs_Update, "its core is newer: update Deckhand on this Mac"
		}
	}
	last := machine_last_line(o.stderr)
	if o.exited && o.exit_code == 255 {
		for p in ([?]string{"Permission denied", "Host key verification failed", "password", "passphrase", "keyboard-interactive"}) {
			if strings.contains(o.stderr, p) do return .Needs_Login, last
		}
	}
	if o.exited && (o.exit_code == 127 || o.exit_code == 126) do return .Not_Installed, "no Deckhand core at its path"
	return .Offline, last != "" ? last : "the connection ended"
}

@(private = "file")
machine_last_line :: proc(text: string) -> string {
	t := strings.trim_space(text)
	if i := strings.last_index_byte(t, '\n'); i >= 0 do t = t[i + 1:]
	return strings.trim_space(t)
}

// ---- backoff ----

Machine_Backoff :: struct {
	delay:    time.Duration, // the next wait (0: MACHINE_BACKOFF_MIN)
	up_since: time.Tick, // {}: not up
}

machine_backoff_up :: proc(b: ^Machine_Backoff, now: time.Tick) {b.up_since = now}

// The link went down (or an attempt failed): how long to wait before the next.
machine_backoff_down :: proc(b: ^Machine_Backoff, now: time.Tick) -> time.Duration {
	if b.up_since != {} && time.tick_diff(b.up_since, now) >= MACHINE_UP_RESET do b.delay = 0
	b.up_since = {}
	wait := b.delay > 0 ? b.delay : MACHINE_BACKOFF_MIN
	b.delay = min(wait * 2, MACHINE_BACKOFF_MAX)
	return wait
}

// ---- the registry ----

machines_path :: proc() -> string {
	if home_root == "" do return ""
	return fmt.tprintf("%s/%s", strings.trim_right(home_root, "/"), MACHINES_FILE)
}

// Reads path ("" or missing: none). Strings in allocator.
machines_read :: proc(path: string, allocator := context.allocator) -> (list: [dynamic]Machine, next: u64, ok: bool) {
	list = make([dynamic]Machine, allocator)
	next = 1
	b, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil do return list, next, !os.exists(path)
	v, jerr := jg.parse_string(string(b), .JSON, true, context.temp_allocator)
	if jerr != nil do return list, next, false
	obj, is := v.(json.Object)
	if !is do return list, next, false
	if n, nok := obj["next"].(json.Integer); nok && n >= 1 && n <= MACHINE_NO_MAX + 1 do next = u64(n)
	arr, _ := obj["machines"].(json.Array)
	str :: proc(o: json.Object, k: string, a: runtime.Allocator) -> string {
		s, _ := o[k].(json.String)
		return strings.clone(s, a)
	}
	for e in arr {
		o, eok := e.(json.Object)
		if !eok do continue
		no, nok := o["no"].(json.Integer)
		if !nok || no < 1 || no > MACHINE_NO_MAX do continue
		m := Machine{no = u64(no), name = str(o, "name", allocator), target = str(o, "target", allocator), os = str(o, "os", allocator), arch = str(o, "arch", allocator), core_path = str(o, "core_path", allocator), via = str(o, "via", allocator)}
		append(&list, m)
		if m.no >= next do next = m.no + 1
	}
	return list, next, true
}

// Writes the registry, 0600, through a temp file and a rename. "" = written.
machines_write :: proc(path: string, list: []Machine, next: u64) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"next":%d,"machines":[`, next)
	for m, i in list {
		if i > 0 do strings.write_byte(&b, ',')
		fmt.sbprintf(&b, `{{"no":%d`, m.no)
		for kv in ([?][2]string{{"name", m.name}, {"target", m.target}, {"os", m.os}, {"arch", m.arch}, {"core_path", m.core_path}}) {
			fmt.sbprintf(&b, `,"%s":`, kv[0])
			json_quote(&b, kv[1])
		}
		if m.via != "" {
			strings.write_string(&b, `,"via":`)
			json_quote(&b, m.via)
		}
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, "]}\n")
	text := strings.to_string(b)
	tmp := fmt.tprintf("%s.new", path)
	os.remove(tmp)
	fd := posix.open(strings.clone_to_cstring(tmp, context.temp_allocator), {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return fmt.tprintf("cannot write %s", tmp)
	ok := posix.write(fd, raw_data(text), uint(len(text))) == len(text)
	posix.close(fd)
	if !ok || posix.rename(strings.clone_to_cstring(tmp, context.temp_allocator), strings.clone_to_cstring(path, context.temp_allocator)) != 0 {
		os.remove(tmp)
		return fmt.tprintf("cannot write %s", path)
	}
	return ""
}

// ---- the links (main thread) ----

@(private = "file")
Mach_Phase :: enum u8 {
	Idle, // waiting for next_at
	Probe, // uname -sm
	Hello, // connect runs: waiting for its hello reply line
	Up, // frames
	Stopped, // taken, removed, or the setting is off: no retry
}

@(private = "file")
Mach_Link :: struct {
	using m:   Machine, // heap strings
	phase:     Mach_Phase,
	status:    Machine_Status,
	version:   string, // heap
	error:     string, // heap
	pid:       posix.pid_t,
	fd:        posix.FD, // our end of the socketpair (-1: none)
	err_fd:    posix.FD, // the child's stderr (-1: none)
	errbuf:    [dynamic]u8,
	inbuf:     [dynamic]u8, // a probe's output, or the bytes before the hello reply's newline
	started:   time.Tick,
	next_at:   time.Tick,
	backoff:   Machine_Backoff,
	sock:      ^cw.Sock_Transport,
	exit_code: int,
	exited:    bool,
}

@(private = "file")
mach: struct {
	links:  [dynamic]^Mach_Link,
	next:   u64,
	loaded: bool,
	from:   string, // heap: this Mac's name (machine_from_name)
	arena:  virtual.Arena, // what state.machines points into
	dropped: int, // window.request and confirmation.parked dropped from hub links (tests, logs)
}

// Dropped from hub links so far (tests).
machines_dropped :: proc() -> int {return mach.dropped}

// At serve's start (home_root set): the registry, this Mac's name, the machines section.
machines_load :: proc() {
	heap := runtime.heap_allocator()
	list, next, ok := machines_read(machines_path(), heap)
	if !ok do fmt.eprintln("Deckhand: machines.json could not be read: no machines until it is fixed or removed")
	mach.next = next
	mach.links = make([dynamic]^Mach_Link, heap)
	for m in list {
		l := new(Mach_Link, heap)
		l.m = m
		l.fd, l.err_fd = -1, -1
		append(&mach.links, l)
	}
	delete(list)
	host: [256]u8
	name := "mac"
	if posix.gethostname(&host[0], len(host) - 1) == .OK do name = string(cstring(&host[0]))
	mach.from = strings.clone(machine_from_name(name), heap)
	mach.loaded = ok
	machines_publish()
}

// The machines section, from the links (after any change a window should see).
@(private = "file")
machines_publish :: proc() {
	virtual.arena_free_all(&mach.arena)
	a := virtual.arena_allocator(&mach.arena)
	views := make([dynamic]Machine_View, 0, len(mach.links), a)
	for l in mach.links {
		append(&views, Machine_View{no = l.no, name = strings.clone(l.name, a), target = strings.clone(l.target, a), status = l.status, version = strings.clone(l.version, a), os = strings.clone(l.os, a), arch = strings.clone(l.arch, a), error = strings.clone(l.error, a)})
	}
	state.machines = views[:]
	window_state_changed()
}

@(private = "file")
machines_save :: proc() -> string {
	path := machines_path()
	if path == "" do return "no data dir"
	list := make([dynamic]Machine, context.temp_allocator)
	for l in mach.links do append(&list, l.m)
	return machines_write(path, list[:], mach.next)
}

@(private = "file")
mlink_set :: proc(l: ^Mach_Link, s: Machine_Status, why := "", version := "") {
	heap := runtime.heap_allocator()
	if l.status == s && l.error == why && l.version == version do return
	l.status = s
	delete(l.error, heap)
	l.error = strings.clone(why, heap)
	if s == .Online || version != "" {
		delete(l.version, heap)
		l.version = strings.clone(version, heap)
	}
	if autotest_active do fmt.printfln("[autotest] machine %s: %s%s%s", l.name, MACHINE_STATUS_NAMES[s], why != "" ? ": " : "", why)
	machines_publish()
}

MACHINE_STATUS_NAMES := [Machine_Status]string {
	.Connecting    = "connecting",
	.Online        = "online",
	.Offline       = "offline",
	.Needs_Login   = "needs_login",
	.Needs_Update  = "needs_update",
	.Not_Installed = "not_installed",
	.Taken         = "taken",
}

// Ends what runs for l: its process group gets SIGTERM and the tick reaps it, or (wait) SIGKILL and
// it is reaped here.
@(private = "file")
mlink_close :: proc(l: ^Mach_Link, wait := false) {
	heap := runtime.heap_allocator()
	if l.sock != nil {
		cw.sock_destroy(l.sock) // closes l.fd
		free(l.sock, heap)
		l.sock = nil
		l.fd = -1
	}
	if l.fd >= 0 do posix.close(l.fd)
	if l.err_fd >= 0 do posix.close(l.err_fd)
	l.fd, l.err_fd = -1, -1
	if l.pid > 0 && !l.exited {
		posix.kill(-l.pid, wait ? .SIGKILL : .SIGTERM) // waiting: it must go now
		if wait {
			st: i32
			for posix.waitpid(l.pid, &st, {}) < 0 && posix.errno() == .EINTR {}
			l.exited = true
		}
	}
	clear(&l.inbuf)
	clear(&l.errbuf)
}

// The link ended without a hub.taken: a status from what it came to, then a wait (backoff).
@(private = "file")
mlink_down :: proc(l: ^Mach_Link, o: Machine_Outcome) {
	s, why := machine_status_of(o)
	mlink_close(l)
	l.phase = .Idle
	l.next_at = time.tick_add(time.tick_now(), machine_backoff_down(&l.backoff, time.tick_now()))
	mlink_set(l, s, why)
}

// Starts l's probe or connect. False: it could not start (status set, retried later).
@(private = "file")
mlink_start :: proc(l: ^Mach_Link) {
	run, rwhy := sock_runtime_dir_why(context.temp_allocator)
	probe := l.via == "" && l.os == ""
	argv, why := machine_argv(l.m, run, mach.from, probe)
	if rwhy != "" do why = rwhy
	if why != "" {
		l.phase = .Stopped // a bad entry or a release build's via: nothing to retry
		mlink_set(l, .Offline, why)
		return
	}
	if l.pid > 0 && !l.exited { // the last attempt's process did not go on SIGTERM: it goes now
		posix.kill(-l.pid, .SIGKILL)
		st: i32
		for posix.waitpid(l.pid, &st, {}) < 0 && posix.errno() == .EINTR {}
		l.exited = true
	}
	pid, fd, efd, ok := machine_spawn(argv)
	if !ok {
		mlink_down(l, {exited = true, exit_code = -1, stderr = fmt.tprintf("cannot run %s", argv[0])})
		return
	}
	l.pid, l.fd, l.err_fd, l.exited, l.exit_code = pid, fd, efd, false, 0
	l.phase = probe ? .Probe : .Hello
	l.started = time.tick_now()
	if autotest_active do fmt.printfln("[autotest] machine %s: %s", l.name, probe ? "probe" : "connect")
	mlink_set(l, .Connecting)
}

// Spawns argv (looked up on PATH) in its own process group: stdin and stdout one end of a
// socketpair (fd, ours: nonblocking), stderr a pipe (efd, ours: nonblocking). Nothing else of
// ours reaches it.
@(private = "file")
machine_spawn :: proc(argv: []string) -> (pid: posix.pid_t, fd, efd: posix.FD, ok: bool) {
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	sp: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, .IP, &sp) != .OK do return 0, -1, -1, false
	ep: [2]posix.FD
	if posix.pipe(&ep) != .OK {
		posix.close(sp[0]); posix.close(sp[1])
		return 0, -1, -1, false
	}
	for x in ([4]posix.FD{sp[0], sp[1], ep[0], ep[1]}) do posix.fcntl(x, .SETFD, i32(posix.FD_CLOEXEC))
	attr, fa: [512]u8
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawnattr_setpgroup(&attr, 0)
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_adddup2(&fa, i32(sp[1]), 0)
	posix_spawn_file_actions_adddup2(&fa, i32(sp[1]), 1)
	posix_spawn_file_actions_adddup2(&fa, i32(ep[1]), 2)
	sync.rw_mutex_shared_lock(&fork_lock)
	err := posix.posix_spawnp(&pid, cargv[0], &fa, &attr, raw_data(cargv), posix.environ)
	sync.rw_mutex_shared_unlock(&fork_lock)
	posix.close(sp[1])
	posix.close(ep[1])
	if err != .NONE {
		posix.close(sp[0]); posix.close(ep[0])
		return 0, -1, -1, false
	}
	for x in ([2]posix.FD{sp[0], ep[0]}) do posix.fcntl(x, .SETFL, posix.fcntl(x, .GETFL) | posix.O_NONBLOCK)
	return pid, sp[0], ep[0], true
}

// The fds the core loop polls for the links (into out; returns how many).
machines_poll_fds :: proc(out: []posix.pollfd) -> int {
	n := 0
	for l in mach.links {
		if n >= len(out) do break
		if l.fd < 0 do continue
		ev: posix.Poll_Event = {.IN}
		if l.sock != nil && cw.sock_wants_write(l.sock) do ev += {.OUT}
		out[n] = {fd = l.fd, events = ev}
		n += 1
	}
	return n
}

// The core loop's turn: start what is due, read what came, reap what ended. Main thread.
machines_tick :: proc() {
	if !mach.loaded && mach.links == nil do return
	on := state.settings.remote_machines && core_separate
	now := time.tick_now()
	for l in mach.links {
		if !on { // the setting went off: every link ends; turned on again, each starts afresh
			if l.phase != .Idle || l.fd >= 0 do mlink_close(l)
			mlink_reap(l)
			l.phase, l.next_at, l.backoff = .Idle, {}, {}
			mlink_set(l, .Offline, "Machines over SSH is off")
			continue
		}
		mlink_reap(l)
		switch l.phase {
		case .Stopped:
		case .Idle:
			if l.next_at == {} || time.tick_diff(l.next_at, now) >= 0 do mlink_start(l)
		case .Probe:
			mlink_read_err(l)
			mlink_read_raw(l, MACHINE_STDERR_MAX)
			if l.exited {
				if os_name, arch, ok := machine_uname_parse(string(l.inbuf[:])); ok && l.exit_code == 0 {
					heap := runtime.heap_allocator()
					delete(l.os, heap); delete(l.arch, heap); delete(l.core_path, heap)
					l.os, l.arch, l.core_path = strings.clone(os_name, heap), strings.clone(arch, heap), strings.clone(machine_core_path_for(os_name), heap)
					if w := machines_save(); w != "" do fmt.eprintln("Deckhand: machines:", w)
					mlink_close(l)
					l.phase = .Idle
					l.next_at = now
				} else if l.exit_code == 0 {
					l.phase = .Stopped
					mlink_close(l)
					mlink_set(l, .Offline, fmt.tprintf("not a Mac or Linux: %s", strings.trim_space(string(l.inbuf[:]))))
				} else do mlink_down(l, {exited = true, exit_code = l.exit_code, stderr = string(l.errbuf[:])})
			}
		case .Hello:
			mlink_read_err(l)
			mlink_read_raw(l, 1 << 20)
			if nl := strings.index_byte(string(l.inbuf[:]), '\n'); nl >= 0 {
				mlink_hello(l, string(l.inbuf[:nl]), l.inbuf[nl + 1:])
			} else if l.exited { // its stdout's EOF alone waits for the exit: the exit code says why
				mlink_down(l, {exited = true, exit_code = l.exit_code, stderr = string(l.errbuf[:])})
			} else if time.tick_diff(l.started, now) > MACHINE_HELLO_WAIT {
				mlink_down(l, {stderr = "no answer from its core"})
			}
		case .Up:
			mlink_read_err(l)
			mlink_pump(l)
		}
	}
}

// The hello reply line came: online (frames from here on) or a status.
@(private = "file")
mlink_hello :: proc(l: ^Mach_Link, line: string, rest: []u8) {
	o := Machine_Outcome{replied = true}
	o.ok = json_path(line, "result.ok") == "true" && json_path(line, "result.data.framed") == "true"
	if !o.ok {
		o.error = json_path(line, "result.error")
		if o.error == "" || o.error == "<invalid json>" do o.error = "its core did not take the hub"
		mlink_down(l, o)
		return
	}
	gen, _ := strconv.parse_i64(json_path(line, "result.data.generation"))
	version := json_path(line, "result.data.version")
	o.skew = cw.skew_check(cw.GENERATION, gen, core_version(), version)
	s, why := machine_status_of(o)
	if s != .Online {
		mlink_down(l, o)
		return
	}
	heap := runtime.heap_allocator()
	if mos, march := json_path(line, "result.data.machine.os"), json_path(line, "result.data.machine.arch"); mos != l.os || march != l.arch {
		delete(l.os, heap); delete(l.arch, heap)
		l.os, l.arch = strings.clone(mos, heap), strings.clone(march, heap)
	}
	l.sock = new(cw.Sock_Transport, heap)
	cw.sock_open(l.sock, l.fd, initial = rest, allocator = heap)
	clear(&l.inbuf)
	l.phase = .Up
	machine_backoff_up(&l.backoff, time.tick_now())
	mlink_set(l, .Online, why, version)
}

// Frames from an online link. Caps from the first byte: what a window would act on is dropped
// here, unread (§8.3). M6-B reads the state stream; nothing else is taken yet.
@(private = "file")
mlink_pump :: proc(l: ^Mach_Link) {
	if _, why := cw.sock_flush(l.sock); why != .None {
		mlink_down(l, {stderr = "the connection ended"})
		return
	}
	for _ in 0 ..< 256 {
		f, err := cw.sock_recv(l.sock, context.temp_allocator)
		if err == .Closed {
			mlink_reap(l)
			mlink_down(l, {exited = l.exited, exit_code = l.exit_code, stderr = len(l.errbuf) > 0 ? string(l.errbuf[:]) : "the connection ended"})
			return
		}
		if err != .None do return
		if f.channel != cw.JSON_CHANNEL || f.kind != u8(cw.Kind.Data) do continue
		switch hub_msg_type(string(f.payload)) {
		case "window.request", "confirmation.parked":
			mach.dropped += 1
			if autotest_active do fmt.printfln("[autotest] machine %s: dropped %s", l.name, hub_msg_type(string(f.payload)))
		case "hub.taken":
			by := json_path(string(f.payload), "by")
			mlink_close(l)
			l.phase = .Stopped
			l.backoff = {}
			mlink_set(l, .Taken, by != "" && by != "<invalid json>" ? fmt.tprintf("viewed from %s", by) : "in use by that machine's own window")
			return
		}
	}
}

// A message's type, read without decoding the rest ("" = not one).
hub_msg_type :: proc(text: string) -> string {
	v, err := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if err != nil do return ""
	o, ok := v.(json.Object)
	if !ok do return ""
	t, _ := o["type"].(json.String)
	return t
}

@(private = "file")
mlink_read_raw :: proc(l: ^Mach_Link, cap: int) {
	if l.fd < 0 do return
	buf: [16 << 10]u8
	for len(l.inbuf) < cap {
		n := posix.read(l.fd, &buf[0], len(buf))
		if n > 0 {
			append(&l.inbuf, ..buf[:n])
			continue
		}
		if n == 0 { // EOF: the child closed its end
			posix.close(l.fd)
			l.fd = -1
		}
		return
	}
}

@(private = "file")
mlink_read_err :: proc(l: ^Mach_Link) {
	if l.err_fd < 0 do return
	buf: [4096]u8
	for {
		n := posix.read(l.err_fd, &buf[0], len(buf))
		if n <= 0 {
			if n == 0 {
				posix.close(l.err_fd)
				l.err_fd = -1
			}
			return
		}
		room := MACHINE_STDERR_MAX - len(l.errbuf)
		if room > 0 do append(&l.errbuf, ..buf[:min(int(n), room)])
	}
}

@(private = "file")
mlink_reap :: proc(l: ^Mach_Link) {
	if l.pid <= 0 || l.exited do return
	st: i32
	if posix.waitpid(l.pid, &st, {.NOHANG}) != l.pid do return
	l.exited = true
	if posix.WIFEXITED(st) do l.exit_code = int(posix.WEXITSTATUS(st))
	else do l.exit_code = -1
	mlink_read_err(l)
}

// At the core's end: every link closed, every child reaped.
machines_stop :: proc() {
	for l in mach.links do mlink_close(l, wait = true)
}

@(private = "file")
mlink_find :: proc(no: u64) -> (^Mach_Link, int) {
	for l, i in mach.links do if l.no == no do return l, i
	return nil, -1
}

@(private = "file")
mlink_free :: proc(l: ^Mach_Link) {
	heap := runtime.heap_allocator()
	for s in ([?]string{l.name, l.target, l.os, l.arch, l.core_path, l.via, l.version, l.error}) do delete(s, heap)
	delete(l.inbuf)
	delete(l.errbuf)
	free(l, heap)
}

// ---- the commands (user-only: command_table.odin) ----

machine_add_apply :: proc(c: Machine_Add) -> Result {
	if !state.settings.remote_machines do return fail("turn on Settings › Experimental › Machines over SSH first")
	if !core_separate do return fail("machines need Sessions in a background core (the gear)")
	if !mach.loaded do return fail("machines.json could not be read: fix or remove it first")
	name := strings.trim_space(c.name)
	if w := machine_name_error(name); w != "" do return fail(w)
	for l in mach.links do if strings.equal_fold(l.name, name) do return fail(fmt.tprintf("a machine is already called %s", name))
	if c.via != "" {
		if !TEST_HOOKS do return fail("via is only for development and test builds")
	} else if w := machine_target_error(c.target); w != "" do return fail(w)
	if mach.next > MACHINE_NO_MAX do return fail("no machine numbers left")
	heap := runtime.heap_allocator()
	l := new(Mach_Link, heap)
	l.m = Machine{no = mach.next, name = strings.clone(name, heap), target = strings.clone(c.target, heap), via = strings.clone(c.via, heap)}
	l.fd, l.err_fd = -1, -1
	mach.next += 1
	append(&mach.links, l)
	if w := machines_save(); w != "" {
		pop(&mach.links)
		mach.next -= 1
		mlink_free(l)
		return fail(w)
	}
	machines_publish()
	return {ok = true, created_id = l.no}
}

machine_remove_apply :: proc(c: Machine_Remove) -> Result {
	l, i := mlink_find(c.no)
	if l == nil do return fail(fmt.tprintf("no machine %d", c.no))
	mlink_close(l, wait = true)
	ordered_remove(&mach.links, i)
	if w := machines_save(); w != "" {
		inject_at(&mach.links, i, l)
		return fail(w)
	}
	mlink_free(l)
	machines_publish()
	return {ok = true}
}

machine_connect_apply :: proc(c: Machine_Connect) -> Result {
	l, _ := mlink_find(c.no)
	if l == nil do return fail(fmt.tprintf("no machine %d", c.no))
	if !state.settings.remote_machines do return fail("turn on Settings › Experimental › Machines over SSH first")
	if l.phase == .Up || l.phase == .Hello || l.phase == .Probe do return {ok = true}
	mlink_close(l)
	l.phase, l.next_at, l.backoff = .Idle, {}, {}
	return {ok = true}
}
