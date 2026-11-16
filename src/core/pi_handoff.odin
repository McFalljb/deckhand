package core

// Continue this conversation on <machine> (docs/GUIDE.md, Other machines; #115): a copy of one of
// this Mac's pi transcripts goes to the project of the same folder name on another machine, whose
// core forks it into a new pi session there with pi's own `--fork` (as Atlas's move, home.odin).
// The session here is left as it is; the one there gets a new id. Only pi, only from this Mac
// outward, only the user's at this window.
//
// This Mac (pi_handoff): the user's (ui, never a hub's, Atlas's or a script's: who .User_Here and
// caller.kind .UI) on a pi session of a project of this Mac's that has its transcript file here,
// to the remote project its row showed (to_project_id; that machine's core run and the project's
// folder then, checked again here, as step 1's rows are: ui_handoff.odin). Only to a machine whose
// hello lists pi_handoff (FEATURE_PI_HANDOFF), refused before anything is sent otherwise. One at a
// time. The file's whole lines (up to the last newline when it was opened; at most
// PI_HANDOFF_MAX) go as pi_handoff_part commands, PI_HANDOFF_PART bytes each (base64), one after
// the other's answer, on that machine's link as the user's (machine_handoff_send). The last
// answer's created_id (that machine's new session) finishes the request.
//
// That machine (pi_handoff_part): only a hub's, on behalf of its user (caller.hub, kind ui; never
// this machine's own window, Atlas or a script). The bytes are untrusted: one copy coming in at a
// time, parts in order from offset 0, each at most PI_HANDOFF_PART, all at most PI_HANDOFF_MAX;
// written to a file this core names (random) in its own <data dir>/pi-handoff/ (0700; the file
// 0600, O_EXCL, O_NOFOLLOW), never in pi's store and never at a path the hub names. Once whole,
// its first line must be a pi session header ({"type":"session", "id"}), else it is dropped. Its
// new id is a name-based UUID of the header's id, the project's folder and the copy's SHA-256, so
// sending the same copy again lands on the same id: an open session with that id is shown, a
// session file with it is resumed, else a pi tab starts as `pi --fork <copy> --session-id <id>` in
// the project's folder (pi writes the new session file). The copy goes once that file is there,
// or that tab exited or its session closed (pi_handoff_tick). A copy that stops coming
// (PI_HANDOFF_IDLE), comes out of order or fails a check is deleted; what a crash leaves in the
// folder goes at the next start.

import "base:runtime"
import "core:crypto"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:encoding/json"
import "core:encoding/uuid"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

import jg "../jsonguard"

PI_HANDOFF_MAX :: 256 << 20 // a transcript larger than this is not sent (nor taken)
PI_HANDOFF_PART :: 1 << 20 // bytes of it per pi_handoff_part (base64 on the wire)
PI_HANDOFF_PART_B64 :: (4 * PI_HANDOFF_PART / 3 + 3) &~ 3 // its base64, at most
PI_HANDOFF_IDLE :: 60 * time.Second // a copy coming in with no part for this long is dropped
PI_HANDOFF_HEADER_MAX :: 64 << 10 // its first line, the header, is at most this long
PI_HANDOFF_TAIL_MAX :: 16 << 20 // its last newline is looked for this far back from its end, at most
PI_HANDOFF_DIR :: "pi-handoff" // in the data dir

PI_HANDOFF_OLD :: "its Deckhand is too old to take a conversation from here: update Deckhand there (Update in its row's menu in the sidebar), then try again"
PI_HANDOFF_GONE :: "that machine or its project changed since the menu showed it: choose it again"

Pi_Handoff :: struct {
	project_id:    u64, // this Mac's project
	pi_session_id: string, // its pi session, whose transcript file is here
	to_project_id: u64, // the project of the same name on another machine (packed: not an id field, so it never routes the command)
	run:           string, // that machine's core run when its row was drawn
	folder:        string, // and that project's folder then
}

Pi_Handoff_Part :: struct {
	project_id: u64, // the receiving machine's project
	offset:     u64, // where data goes: the bytes taken so far
	data:       string, // base64
	last:       bool, // the copy is whole
}

// ---- this Mac: the menu's rows ----

// The rows "Continue this conversation on <machine> in <project>" for this Mac's pi session sid of
// project pid (temp): one per project of the same name on an online machine that takes one (its
// hello's pi_handoff), as step 1 lists them (handoff_targets); none for a session with no pi
// transcript file here (a Claude Code or Codex row, a remote project's).
pi_handoff_targets :: proc(pid: u64, sid: string) -> []Handoff_Target {
	out := make([dynamic]Handoff_Target, context.temp_allocator)
	p := find_project(pid)
	if p == nil || sid == "" || p.machine != 0 || id_machine(pid) != 0 || p.group != .Projects do return out[:]
	targets := handoff_targets(pid)
	if len(targets) == 0 || !strings.has_suffix(find_session_file(p^, sid), ".jsonl") do return out[:]
	for t in targets {
		if t.project_id == 0 || !machine_pi_handoff(t.machine) do continue
		x := t
		x.label = fmt.tprintf("Continue this conversation on %s", strings.trim_prefix(t.label, "New session on "))
		append(&out, x)
	}
	return out[:]
}

// Whether machine no's core takes a conversation from here (its hello's pi_handoff).
machine_pi_handoff :: proc(no: u64) -> bool {
	for m in state.machines do if m.no == no do return m.pi_handoff
	return false
}

// ---- this Mac: sending ----

@(private = "file")
handoff_out: struct {
	id:         u64, // the one being sent (0: none)
	next:       u64,
	request_id: u64,
	machine:    u64,
	to_project: u64, // packed
	fd:         posix.FD,
	size:       u64, // its whole lines when it was opened
	sent:       u64, // bytes sent (the last part's may not be answered yet)
	what:       string, // heap: "nuc in api", for the toasts
}

// pi_handoff, the user's at this window: the first part is sent (pending), or why not.
pi_handoff_apply :: proc(c: Pi_Handoff, caller: Caller, request_id: u64) -> Result {
	if caller.kind != .UI || caller_from_hub(caller) do return fail("only you, at this Mac's window, can continue a conversation on another machine")
	if handoff_out.id != 0 do return fail("a conversation is being copied to another machine already: try again once it is done")
	p := find_project(c.project_id)
	if p == nil || p.machine != 0 || id_machine(c.project_id) != 0 || p.group != .Projects do return fail("only a session of a project on this Mac can be continued on another machine")
	if c.pi_session_id == "" do return fail("pi_session_id is empty")
	path := find_session_file(p^, c.pi_session_id)
	if !strings.has_suffix(path, ".jsonl") do path = "" // pi's own: a Claude row's id never names one
	if path == "" do return fail("this session has no pi transcript on this Mac")
	no := id_machine(c.to_project_id)
	m: ^Machine_View
	for &x in state.machines do if no != 0 && x.no == no do m = &x
	rp := find_project(c.to_project_id)
	if m == nil || m.status != .Online || m.core_run != c.run || rp == nil || rp.machine != no || rp.cwd != c.folder || rp.group != .Projects do return fail(PI_HANDOFF_GONE)
	name := handoff_name(p.cwd)
	if name == "" || handoff_name(rp.cwd) != name do return fail(fmt.tprintf("that project on %s is not called %s", m.name, name))
	if !m.pi_handoff do return fail(fmt.tprintf("on %s: %s", m.name, PI_HANDOFF_OLD))
	if !machine_link_up(no) do return {error = fmt.tprintf("%s is not connected", m.name), data = `{"code":"machine_offline"}`}
	// pi's own file in its sessions folder: never through a link to another file (O_NOFOLLOW), nor a
	// session folder that leads out of that folder (review 1)
	root := real_path(sessions_root(context.temp_allocator))
	if rp := real_path(path); root == "" || !strings.has_prefix(rp, strings.concatenate({strings.trim_right(root, "/"), "/"}, context.temp_allocator)) do return fail("this session's transcript is not in pi's sessions folder")
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW, .CLOEXEC})
	if fd < 0 do return fail("cannot read this session's transcript (it must be a file, not a link)")
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) {
		posix.close(fd)
		return fail("this session's transcript is not a file")
	}
	if i64(st.st_size) > PI_HANDOFF_MAX {
		posix.close(fd)
		return fail(fmt.tprintf("this conversation is %d MB: at most %d MB can be continued on another machine", i64(st.st_size) >> 20, PI_HANDOFF_MAX >> 20))
	}
	size := whole_lines(fd, u64(max(i64(st.st_size), 0)))
	if size == 0 {
		posix.close(fd)
		return fail(fmt.tprintf("this session's transcript has no whole line in its last %d MB", PI_HANDOFF_TAIL_MAX >> 20))
	}
	// the same check the other machine makes, before anything is sent
	if _, why := handoff_header_fd(fd); why != "" {
		posix.close(fd)
		return fail(why)
	}
	handoff_out.next += 1
	handoff_out = {id = handoff_out.next, next = handoff_out.next, request_id = request_id, machine = no, to_project = c.to_project_id, fd = fd, size = size, what = fmt.aprintf("%s in %s", m.name, name, allocator = runtime.heap_allocator())}
	if r := handoff_send_next(); !r.pending {
		handoff_out_end()
		return r
	}
	return {ok = true, pending = true}
}

// The bytes of a transcript up to its last newline (size: its size now): pi may be writing its
// next line. Read backwards from the end, at most PI_HANDOFF_TAIL_MAX of it. 0: none there.
@(private = "file")
whole_lines :: proc(fd: posix.FD, size: u64) -> u64 {
	buf: [64 << 10]u8
	end := size
	for end > 0 && size - end < PI_HANDOFF_TAIL_MAX {
		n := min(end, u64(len(buf)))
		if !read_full(fd, buf[:n], end - n) do return 0
		for i := int(n) - 1; i >= 0; i -= 1 do if buf[i] == '\n' do return end - n + u64(i) + 1
		end -= n
	}
	return 0
}

@(private = "file")
read_full :: proc(fd: posix.FD, buf: []u8, at: u64) -> bool {
	got := 0
	for got < len(buf) {
		n := posix.pread(fd, raw_data(buf[got:]), uint(len(buf)) - uint(got), posix.off_t(at + u64(got)))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do return false
		got += int(n)
	}
	return true
}

// The next part to that machine: pending, or why it could not go.
@(private = "file")
handoff_send_next :: proc() -> Result {
	o := &handoff_out
	n := min(o.size - o.sent, PI_HANDOFF_PART)
	buf := make([]u8, n, context.temp_allocator)
	if !read_full(o.fd, buf, o.sent) do return fail("cannot read this session's transcript")
	data, _ := base64.encode(buf, allocator = context.temp_allocator)
	part := Pi_Handoff_Part{project_id = o.to_project, offset = o.sent, data = data, last = o.sent + n == o.size}
	r := machine_handoff_send(part, o.machine, o.id)
	if r.pending do o.sent += n
	return r
}

// Machine no's answer to part of handoff id (machine_route.odin's forward_finish; r as route_result
// made it, created_id packed): the next part, or the end.
pi_handoff_answer :: proc(id, no: u64, r: Result) {
	o := &handoff_out
	if id == 0 || id != o.id || no != o.machine do return
	if r.ok && o.sent < o.size {
		if nr := handoff_send_next(); !nr.pending do handoff_finish(nr)
		return
	}
	handoff_finish(r)
}

@(private = "file")
handoff_finish :: proc(r: Result) {
	o := &handoff_out
	req, no := o.request_id, o.machine
	r := r
	if r.ok {
		window_toast(fmt.tprintf("Continued on %s as a new session; this one stays here", o.what))
		// its new session: shown here, as a session it opened for a forwarded command is
		if s := find_session(r.created_id); s != nil && s.machine == no && state.current_session != s.id do run_command(Focus_Session{session = s.id}, {kind = .Internal})
	} else {
		if r.error == "" do r.error = fmt.tprintf("on %s: it did not work", machine_name(no))
		window_toast(fmt.tprintf("Continue on %s: %s", o.what, r.error), err = true)
	}
	handoff_out_end()
	emit_event(Finished_Event{request_id = req, result = r})
}

@(private = "file")
handoff_out_end :: proc() {
	o := &handoff_out
	if o.fd > 0 do posix.close(o.fd)
	delete(o.what, runtime.heap_allocator())
	next := o.next
	o^ = {next = next}
}

// ---- the other machine: taking one ----

@(private = "file")
handoff_in: struct {
	active:     bool,
	conn:       u64, // the hub connection it comes on (window_link_hub_serial): only its parts are taken
	project_id: u64,
	path:       string, // heap: in handoff_dir, named here
	fd:         posix.FD,
	written:    u64,
	last_at:    time.Tick,
	sha:        hash.Context,
}

// A copy pi was started to fork (its session's pi tab): deleted once pi wrote the new file.
@(private = "file")
Handoff_Fork :: struct {
	session: u64,
	id:      string, // heap: the new pi session id
	dir:     string, // heap: pi's store for the project
	temp:    string, // heap: the copy
}

@(private = "file")
handoff_cap: u64 = PI_HANDOFF_MAX // what this core takes in all (tests lower it)
@(private = "file")
handoff_forks: [dynamic]Handoff_Fork
@(private = "file")
handoff_swept: bool
@(private = "file")
handoff_checked: time.Tick

PI_HANDOFF_HUB_ONLY :: "a conversation comes here only from the machine viewing this one, as its user's"

// One part of a copy from the hub's user: taken (ok), or why not (the copy so far is dropped).
// The last one forks it: created_id = the new session.
pi_handoff_part_apply :: proc(c: Pi_Handoff_Part, caller: Caller) -> (Result, bool) {
	conn := window_link_hub_serial() // the hub connection this part came on (one at a time)
	if caller.kind != .UI || !caller.hub || conn == 0 do return fail(PI_HANDOFF_HUB_ONLY), false
	now := time.tick_now()
	in_ := &handoff_in
	if c.offset == 0 {
		if in_.active {
			if time.tick_diff(in_.last_at, now) < PI_HANDOFF_IDLE do return fail("another conversation is being copied here: try again once it is done"), false
			handoff_in_drop()
		}
		p := find_project(c.project_id)
		if p == nil || p.machine != 0 || id_machine(c.project_id) != 0 || p.group != .Projects do return fail("no such project here"), false
		if pi_fork_too_old() do return fail(fmt.tprintf("pi here is %s: a conversation from another machine needs pi %s or later", state.reload.pi_version, PI_FORK_MIN_PI)), false
		if why := handoff_in_open(c.project_id, conn, now); why != "" do return fail(why), false
	} else if in_.active && in_.conn != conn {
		// another connection's copy: never continued from this one (review 1)
		return fail("another conversation is being copied here: try again once it is done"), false
	} else if !in_.active || c.project_id != in_.project_id || c.offset != in_.written {
		handoff_in_drop()
		return fail("the copy came out of order: try again"), false
	}
	if len(c.data) > PI_HANDOFF_PART_B64 {
		handoff_in_drop()
		return fail("a part of the copy is too large"), false
	}
	bytes, err := base64.decode(c.data, allocator = context.temp_allocator)
	if err != nil || len(bytes) > PI_HANDOFF_PART {
		handoff_in_drop()
		return fail("a part of the copy is not valid"), false
	}
	if in_.written + u64(len(bytes)) > handoff_cap {
		handoff_in_drop()
		return fail(fmt.tprintf("the conversation is larger than %d MB", PI_HANDOFF_MAX >> 20)), false
	}
	rest := bytes
	for len(rest) > 0 {
		n := posix.write(in_.fd, raw_data(rest), uint(len(rest)))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 {
			handoff_in_drop()
			return fail("cannot write the copy here"), false
		}
		rest = rest[n:]
	}
	hash.update(&in_.sha, bytes)
	in_.written += u64(len(bytes))
	in_.last_at = now
	if !c.last do return {ok = true}, false
	return handoff_in_fork()
}

// The folder of copies: <data dir>/pi-handoff, 0700, a real folder (never a link). "" = none.
@(private = "file")
handoff_dir :: proc() -> string {
	if home_root == "" do return ""
	d, _ := filepath.join({home_root, PI_HANDOFF_DIR}, context.temp_allocator)
	cd := strings.clone_to_cstring(d, context.temp_allocator)
	posix.mkdir(cd, {.IRUSR, .IWUSR, .IXUSR})
	st: posix.stat_t
	if posix.lstat(cd, &st) != .OK || !posix.S_ISDIR(st.st_mode) || st.st_uid != posix.getuid() do return ""
	posix.chmod(cd, {.IRUSR, .IWUSR, .IXUSR})
	return d
}

@(private = "file")
handoff_in_open :: proc(project_id, conn: u64, now: time.Tick) -> string {
	dir := handoff_dir()
	if dir == "" do return "this machine has no folder for a copy"
	r: [16]u8
	crypto.rand_bytes(r[:])
	path := fmt.aprintf("%s/%s.jsonl", dir, string(hex.encode(r[:], context.temp_allocator)), allocator = runtime.heap_allocator())
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 {
		delete(path, runtime.heap_allocator())
		return "cannot make the copy here"
	}
	handoff_in = {active = true, conn = conn, project_id = project_id, path = path, fd = fd, last_at = now}
	hash.init(&handoff_in.sha, .SHA256)
	return ""
}

// Hub connection conn went (window_link.odin): the copy it was sending goes with it (review 1).
pi_handoff_link_gone :: proc(conn: u64) {
	if handoff_in.active && handoff_in.conn == conn do handoff_in_drop()
}

// The copy coming in goes (closed, deleted).
@(private = "file")
handoff_in_drop :: proc() {
	in_ := &handoff_in
	if !in_.active do return
	if in_.fd > 0 do posix.close(in_.fd)
	os.remove(in_.path)
	delete(in_.path, runtime.heap_allocator())
	hash.reset(&in_.sha)
	in_^ = {}
}

// The copy is whole: checked, then forked (or the same copy's session shown again).
@(private = "file")
handoff_in_fork :: proc() -> (Result, bool) {
	in_ := &handoff_in
	posix.close(in_.fd)
	in_.fd = -1
	header_id, why := handoff_header(in_.path)
	p := find_project(in_.project_id)
	if why == "" && p == nil do why = "no such project here"
	if why != "" {
		handoff_in_drop()
		return fail(why), false
	}
	sum: [32]u8
	hash.final(&in_.sha, sum[:])
	cwd := real_path(p.cwd)
	if cwd == "" do cwd = p.cwd
	heap := runtime.heap_allocator()
	id := pi_handoff_fork_id(header_id, cwd, string(hex.encode(sum[:], context.temp_allocator)), heap)
	temp := in_.path // the copy is ours from here
	in_^ = {}
	gone :: proc(temp: string) {
		os.remove(temp)
		delete(temp, runtime.heap_allocator())
	}
	// sent before: its session open here (shown), or its file (resumed)
	for s in state.open_sessions do if !s.home && s.machine == 0 && s.pi_session_id == id {
		gone(temp)
		delete(id, heap)
		focus_session(s.id, {kind = .Internal})
		return {ok = true, created_id = s.id}, true
	}
	if f := find_session_file(p^, id); f != "" {
		gone(temp)
		defer delete(id, heap)
		r, ch := open_new_session(p^, id, f)
		persist.gen += 1
		return r, ch
	}
	r, ch := open_new_session(p^, id, "", fork = temp)
	if !r.ok {
		gone(temp)
		delete(id, heap)
		return r, ch
	}
	dir := p.dir != "" ? p.dir : pi_store_dir(p.cwd)
	if handoff_forks == nil do handoff_forks = make([dynamic]Handoff_Fork, heap)
	append(&handoff_forks, Handoff_Fork{session = r.created_id, id = id, dir = strings.clone(dir, heap), temp = temp})
	persist.gen += 1
	return r, ch
}

// The copy's first line, a pi session header ({"type":"session", "id": …}): its id, or why not.
@(private = "file")
handoff_header :: proc(path: string) -> (id: string, why: string) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NOFOLLOW, .CLOEXEC})
	if fd < 0 do return "", PI_HANDOFF_NOT_PI
	defer posix.close(fd)
	return handoff_header_fd(fd)
}

PI_HANDOFF_NOT_PI :: "it is not a pi conversation (its first line is not a pi session header)"

// The same, of an open file (this Mac checks its own before sending: review 1).
@(private = "file")
handoff_header_fd :: proc(fd: posix.FD) -> (id: string, why: string) {
	NOT :: PI_HANDOFF_NOT_PI
	buf := make([]u8, PI_HANDOFF_HEADER_MAX, context.temp_allocator)
	got := 0
	for got < len(buf) {
		n := posix.pread(fd, raw_data(buf[got:]), uint(len(buf)) - uint(got), posix.off_t(got))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 do break
		got += int(n)
	}
	nl := strings.index_byte(string(buf[:got]), '\n')
	if nl <= 0 do return "", NOT
	v, err := jg.parse(buf[:nl], .JSON, allocator = context.temp_allocator)
	if err != nil do return "", NOT
	obj, ok := v.(json.Object)
	if !ok do return "", NOT
	t, _ := obj["type"].(json.String)
	hid, _ := obj["id"].(json.String)
	_, has_cwd := obj["cwd"].(json.String)
	if t != "session" || hid == "" || len(hid) > 256 || !has_cwd do return "", NOT
	return hid, ""
}

// The id a copy gets here: a name-based UUID (v8, SHA-256) of its header's id, the project's
// folder (a real path) and the copy's SHA-256, so the same copy sent again lands on the same id
// and a later copy of the same conversation (more of it) on another.
pi_handoff_fork_id :: proc(header_id, cwd, digest: string, allocator := context.allocator) -> string {
	ns := uuid.Identifier{0x3f, 0x81, 0x5c, 0x02, 0x9e, 0x47, 0x4b, 0x6d, 0xa1, 0x58, 0x27, 0xc4, 0x90, 0x1e, 0x6b, 0xd5} // Deckhand's conversations from another machine
	name := strings.concatenate({header_id, "\x00", cwd, "\x00", digest}, context.temp_allocator)
	return uuid.to_string(uuid.generate_v8_hash(ns, name, hash.Algorithm.SHA256), allocator)
}

// The core loop's turn (machine_route_tick): a copy coming in with no part for PI_HANDOFF_IDLE
// goes; at the first turn, what an earlier run left in the folder goes; about once a second, a copy
// pi forked goes once its new file is there, or its tab exited (said in the tab when pi wrote
// nothing) or its session closed.
pi_handoff_tick :: proc(now: time.Tick) {
	if handoff_in.active && time.tick_diff(handoff_in.last_at, now) >= PI_HANDOFF_IDLE {
		log_ln("Deckhand: a conversation being copied here stopped coming: dropped")
		handoff_in_drop()
	}
	if !handoff_swept && home_root != "" {
		handoff_swept = true
		handoff_sweep()
	}
	if len(handoff_forks) == 0 do return
	if handoff_checked != {} && time.tick_diff(handoff_checked, now) < time.Second do return
	handoff_checked = now
	heap := runtime.heap_allocator()
	for i := len(handoff_forks) - 1; i >= 0; i -= 1 {
		f := handoff_forks[i]
		s := find_session(f.session)
		wrote := session_file_in(f.dir, f.id) != ""
		exited := s != nil && len(s.tabs) > 0 && s.tabs[0].status == .Exited
		if !wrote && !exited && s != nil && s.pi_session_id == f.id do continue
		if exited && !wrote do if t := term_of(s.tabs[0].id); t != nil do term_note(t, "Deckhand: pi could not open the conversation copied from the other machine (pi --fork); this session has none of it. Close it and continue the conversation from that machine again.")
		os.remove(f.temp)
		delete(f.temp, heap)
		delete(f.id, heap)
		delete(f.dir, heap)
		ordered_remove(&handoff_forks, i)
	}
}

// Every file in the folder of copies but the one coming in and those pi is forking.
@(private = "file")
handoff_sweep :: proc() {
	dir := handoff_dir()
	if dir == "" do return
	files, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	outer: for f in files {
		if f.type != .Regular && f.type != .Symlink do continue
		if handoff_in.active && f.fullpath == handoff_in.path do continue
		for k in handoff_forks do if k.temp == f.fullpath do continue outer
		os.remove(f.fullpath)
	}
}

when TEST_HOOKS {
	// What this core takes in all (tests).
	pi_handoff_cap_for_test :: proc(n: u64) {handoff_cap = n}
	// The copy coming in (tests): its file ("" = none) and bytes so far.
	pi_handoff_in_for_test :: proc() -> (path: string, written: u64) {return handoff_in.path, handoff_in.written}
	// The copies pi is forking (tests): their files.
	pi_handoff_forks_for_test :: proc() -> []string {
		out := make([dynamic]string, context.temp_allocator)
		for f in handoff_forks do append(&out, f.temp)
		return out[:]
	}
	// Back to nothing in flight either way (tests).
	pi_handoff_reset_for_test :: proc() {
		handoff_in_drop()
		handoff_out_end()
		for f in handoff_forks {
			delete(f.temp, runtime.heap_allocator())
			delete(f.id, runtime.heap_allocator())
			delete(f.dir, runtime.heap_allocator())
		}
		clear(&handoff_forks)
		handoff_swept, handoff_checked = false, {}
	}
}
