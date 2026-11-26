package core

// A core or session holder from another login (#202). On macOS a process keeps the audit session
// (the login) it started in. One that outlives a logout keeps running in the dead login: every
// Mach bootstrap lookup it makes fails ("141: Reentrancy avoided"), so the processes it starts
// get no account lookups, no system DNS and no Metal compiler. A window that attached to such a
// core, or a core that adopted such a holder, would start every new session there.
//
// "Another login" is not "a dead login": an ssh login, or a tmux server started from one, is
// another audit session and alive. So a peer is replaced only when (login_replace, pure):
//   - this process runs in the current GUI login: its session has graphic access and is not remote
//     (getaudit_addr's flags), and it is the gui/<uid> launchd domain's session (`launchctl print
//     gui/<uid>`; in an ended login that fails with 141). Not so, or unsure: nothing is replaced;
//   - and the peer runs in another session that is GUI-kind (graphic access, not remote: its flags
//     by auditon(A_GETSINFO_ADDR), which any user may read). A user has one GUI login at a time, so
//     such a session is one that has ended. A remote one (ssh), or one whose flags can't be read,
//     is left alone.
// Otherwise the window or core attaches as before.
//
//   login_replace(current, own, peer) -> bool   the decision (pure)
//   login_should_replace(tok, pid) -> bool       for a socket peer, from its audit token (val[6])
//   login_stop_pid(pid, start, wait) -> gone     SIGTERM, then SIGKILL, by pid and start time
//
// The window checks the core on core.sock (client_core.odin): one to replace is stopped (SIGTERM:
// its handover and save) and a core is launched from this login, once per dial. The core checks
// the holder at connect (holder_client.odin): one to replace is stopped (its sessions end) and a
// new holder starts; workspace.json restores the tabs (pi, Claude and Codex resume, shells start
// fresh). On Linux there is no audit session: nothing is ever replaced.
//
// Test builds: DECKHAND_TEST_ASID=N[:ended|:remote] stands in for this process's session (N: the
// current GUI login; :ended a GUI login that has ended; :remote an ssh login), and a process
// started under it notes it for its pid in the runtime dir (<run>/test-asid-<pid>, login_note),
// which is what a peer then reads for it. A peer with no note counts as this process's session.
// One scene runs a core under one N and a window under another (tests/scripts/other-login.sh).

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "../trust"

// Set once a launch found this process's login ended (macOS: launchd_login_gone, #202): a core
// then exits (src/coremain serve.odin) rather than run on in it. Atomic.
login_gone: bool

LOGIN_ASID_UNKNOWN :: max(u32) // AU_ASSIGN_ASID (-1): never a session a process runs in

// Whether a peer runs in another login than this process: only when both are known.
login_other :: proc(peer, own: u32) -> bool {
	if peer == 0 || own == 0 || peer == LOGIN_ASID_UNKNOWN || own == LOGIN_ASID_UNKNOWN do return false
	return peer != own
}

// A peer's session as the decision needs it.
Login :: struct {
	asid:  u32,
	known: bool, // its flags were read
	gui:   bool, // graphic access, not remote (login_flags_gui_kind)
}

AU_SESSION_FLAG_HAS_GRAPHIC_ACCESS :: 0x0010 // bsm/audit.h
AU_SESSION_FLAG_IS_REMOTE :: 0x1000

login_flags_gui_kind :: proc(flags: u64) -> bool {
	return flags & AU_SESSION_FLAG_HAS_GRAPHIC_ACCESS != 0 && flags & AU_SESSION_FLAG_IS_REMOTE == 0
}

// The decision (see the top). current: this process runs in the current GUI login.
login_replace :: proc(current: bool, own: u32, peer: Login) -> bool {
	return current && peer.known && peer.gui && login_other(peer.asid, own)
}

// The asid in `launchctl print gui/<uid>`'s security context (0 or none: not found).
launchctl_gui_asid :: proc(out: string) -> (asid: u32, ok: bool) {
	ctx := strings.index(out, "security context")
	if ctx < 0 do return 0, false
	rest := out[ctx:]
	i := strings.index(rest, "asid = ")
	if i < 0 do return 0, false
	v := rest[i + len("asid = "):]
	end := 0
	for end < len(v) && v[end] >= '0' && v[end] <= '9' do end += 1
	n, nok := strconv.parse_u64(v[:end], 10)
	if !nok || n == 0 || n >= u64(LOGIN_ASID_UNKNOWN) do return 0, false
	return u32(n), true
}

// DECKHAND_TEST_ASID's value: N, N:ended or N:remote (see the top).
login_hook_parse :: proc(v: string) -> (asid: u32, gui, current, ok: bool) {
	num, _, kind := strings.partition(v, ":")
	n, nok := strconv.parse_u64(num, 10)
	if !nok || n == 0 || n >= u64(LOGIN_ASID_UNKNOWN) do return 0, false, false, false
	switch kind {
	case "": return u32(n), true, true, true
	case "ended": return u32(n), true, false, true
	case "remote": return u32(n), false, false, true
	}
	return 0, false, false, false
}

login_asid_own :: proc() -> u32 {
	when TEST_HOOKS {
		if v := hook_env(.Test_Asid); v != "" {
			a, _, _, _ := login_hook_parse(v)
			return a
		}
	}
	return login_self_real().asid
}

// Tests: 0 = this process's real session decides whether it is GUI-kind; 1 = it is; 2 = it is not.
login_gui_kind_for_test: int

// Whether this process's own session is GUI-kind (graphic access, not remote), whatever its state.
// A launch that fails with 141 from such a session means the GUI login has ended
// (launchd_login_gone); from an ssh session it says nothing of the kind, and the direct start
// stays (`deckhand-core-serve connect` from another machine).
login_own_gui_kind :: proc() -> bool {
	when ODIN_TEST {
		if login_gui_kind_for_test != 0 do return login_gui_kind_for_test == 1
	}
	when TEST_HOOKS {
		if v := hook_env(.Test_Asid); v != "" {
			_, gui, _, _ := login_hook_parse(v)
			return gui
		}
	}
	return login_self_real().gui
}

// Whether this process runs in the current GUI login (see the top). Runs launchctl: called only
// once a peer's session differs.
login_own_current :: proc() -> bool {
	when TEST_HOOKS {
		if v := hook_env(.Test_Asid); v != "" {
			_, _, current, ok := login_hook_parse(v)
			return ok && current
		}
	}
	when ODIN_OS == .Darwin {
		self := login_self_real()
		if !self.known || !self.gui do return false
		out, st := run_group({LAUNCHCTL, "print", fmt.tprintf("gui/%d", posix.getuid())}, 5 * time.Second)
		if st != .Ok do return false // an ended login: 141; no GUI login at all: none
		dom, ok := launchctl_gui_asid(out)
		return ok && dom == self.asid
	} else {
		return false
	}
}

// A socket peer's session, from the audit token read at connect.
login_peer :: proc(tok: trust.Audit_Token, pid: i32) -> Login {
	when TEST_HOOKS {
		if hook_env(.Test_Asid) != "" {
			run, why := sock_runtime_dir_why(context.temp_allocator)
			if why == "" {
				if b, err := os.read_entire_file(login_note_path(run, pid), context.temp_allocator); err == nil {
					a, gui, _, ok := login_hook_parse(strings.trim_space(string(b)))
					if ok do return {asid = a, known = true, gui = gui}
				}
			}
			return {asid = login_asid_own(), known = true, gui = true}
		}
	}
	when ODIN_OS == .Darwin {
		return login_session_real(tok.val[6])
	} else {
		return {}
	}
}

// Whether the peer on a socket (its token read at connect) is to be replaced. The cheap test first:
// launchctl runs only when the sessions differ.
login_should_replace :: proc(tok: trust.Audit_Token, pid: i32) -> bool {
	peer := login_peer(tok, pid)
	own := login_asid_own()
	if !login_other(peer.asid, own) do return false
	current := login_own_current()
	r := login_replace(current, own, peer)
	if !r do log_ln("Deckhand: pid", pid, "runs in another login (session", peer.asid, peer.known ? (peer.gui ? "GUI" : "remote") : "unknown", "; this one", own, current ? "the current GUI login" : "not the current GUI login", "): left alone")
	return r
}

// SIGTERM to pid, SIGKILL after wait, then up to a second for it to go; only while pid is still the
// process that started at start (a reused pid never is). true: it is gone (or was already).
login_stop_pid :: proc(pid: i32, start: i64, wait: time.Duration) -> bool {
	same :: proc(pid: i32, start: i64) -> bool {
		h, ok := lock_proc_ident(pid)
		return ok && h.start == start
	}
	gone :: proc(pid: i32) -> bool {
		_, ok := lock_proc_ident(pid)
		return !ok
	}
	if pid <= 0 || start == 0 do return false
	if !same(pid, start) do return gone(pid) // another process has the pid now: ours is gone
	posix.kill(posix.pid_t(pid), .SIGTERM)
	deadline := time.tick_add(time.tick_now(), wait)
	for same(pid, start) && time.tick_diff(time.tick_now(), deadline) > 0 do time.sleep(20 * time.Millisecond)
	if same(pid, start) {
		posix.kill(posix.pid_t(pid), .SIGKILL)
		for _ in 0 ..< 50 {
			if !same(pid, start) do break
			time.sleep(20 * time.Millisecond)
		}
	}
	return !same(pid, start)
}

// Test builds under DECKHAND_TEST_ASID: notes this process's session for pid (its own, or a
// process it just started: a child runs in its parent's login).
login_note :: proc(pid: i32) {
	when TEST_HOOKS {
		v := hook_env(.Test_Asid)
		if v == "" || pid <= 0 do return
		run, why := sock_runtime_dir_why(context.temp_allocator)
		if why != "" do return
		_ = os.write_entire_file(login_note_path(run, pid), transmute([]u8)fmt.tprintf("%s\n", v))
	}
}

@(private = "file")
login_note_path :: proc(run: string, pid: i32) -> string {
	return fmt.tprintf("%s/test-asid-%d", strings.trim_right(run, "/"), pid)
}

when ODIN_OS == .Darwin {
	// auditinfo_addr_t (bsm/audit.h): 48 bytes, ai_asid at 36.
	@(private = "file")
	Auditinfo_Addr :: struct {
		auid:  u32,
		mask:  [2]u32,
		port:  i32,
		typ:   u32,
		addr:  [4]u32,
		asid:  i32,
		flags: u64,
	}
	#assert(size_of(Auditinfo_Addr) == 48)
	#assert(offset_of(Auditinfo_Addr, asid) == 36)

	foreign import login_libc "system:System"
	@(default_calling_convention = "c")
	foreign login_libc {
		@(link_name = "getaudit_addr")
		login_getaudit_addr :: proc(info: ^Auditinfo_Addr, length: u32) -> i32 ---
		@(link_name = "auditon")
		login_auditon :: proc(cmd: i32, data: rawptr, length: i32) -> i32 ---
	}

	A_GETSINFO_ADDR :: 32 // bsm/audit.h

	// getaudit_addr on oneself needs no privilege.
	@(private = "file")
	login_self_real :: proc() -> Login {
		ai: Auditinfo_Addr
		if login_getaudit_addr(&ai, size_of(ai)) != 0 do return {}
		return {asid = u32(ai.asid), known = true, gui = login_flags_gui_kind(ai.flags)}
	}

	// A session's flags: auditon(A_GETSINFO_ADDR) needs no privilege (only the masks are hidden);
	// a session that is not there fails (EINVAL): not known.
	@(private = "file")
	login_session_real :: proc(asid: u32) -> Login {
		if asid == 0 || asid == LOGIN_ASID_UNKNOWN do return {asid = asid}
		ai: Auditinfo_Addr
		ai.asid = i32(asid)
		if login_auditon(A_GETSINFO_ADDR, &ai, size_of(ai)) != 0 do return {asid = asid}
		return {asid = asid, known = true, gui = login_flags_gui_kind(ai.flags)}
	}
} else {
	@(private = "file")
	login_self_real :: proc() -> Login {return {}}
}

// holder_client_start found a holder of ours to replace (holder_connect's Other_Login): stopped by
// pid and start time (login_stop_pid: its binary may be gone, an old version's folder removed),
// its sessions with it; its socket is removed only once it is gone (a live holder's socket never
// is: it would be unreachable for good). The caller then starts a new holder in this login and the
// tabs restore from workspace.json. The user is told once a window shows it. true: gone.
HOLDER_OTHER_LOGIN_STOP_WAIT :: 3 * time.Second
holder_replace_other_login :: proc(pid: i32, path: string, stop := login_stop_pid) -> bool {
	start := holder_pid_start(pid)
	if start == 0 {
		log_ln("Deckhand: session holder: the one from another login (pid", pid, ") is gone")
		sock_unlink(path)
		return true
	}
	n := holder_children(pid)
	log_ln("Deckhand: session holder: stopping the one from another login (pid", pid, ",", n, "sessions)")
	if !stop(pid, start, HOLDER_OTHER_LOGIN_STOP_WAIT) {
		log_ln("Deckhand: session holder: the one from another login (pid", pid, ") did not stop; its socket stays")
		return false
	}
	sock_unlink(path)
	if autotest_active do fmt.printfln("[autotest] holder: replaced one from another login (pid %d, %d sessions)", pid, n)
	window_toast_shown(login_holder_replaced_text(n))
	return true
}

login_holder_replaced_text :: proc(sessions: int) -> string {
	if sessions <= 0 do return "Deckhand's session holder was from an earlier login, so a new one replaced it."
	return fmt.tprintf("Deckhand's session holder was from an earlier login, so a new one replaced it: %d %s here (pi, Claude and Codex resume their conversations; shells start fresh).", sessions, sessions == 1 ? "session restarts" : "sessions restart")
}
