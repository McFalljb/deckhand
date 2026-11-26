package core

// A core or session holder from another login (#202). On macOS a process keeps the audit session
// (the login) it started in. One that outlives a logout keeps running in the dead login: every
// Mach bootstrap lookup it makes fails ("141: Reentrancy avoided"), so the processes it starts
// get no account lookups, no system DNS and no Metal compiler. A window that attached to such a
// core, or a core that adopted such a holder, would start every new session there.
//
//   login_other(peer, own) -> bool     the decision (pure): both known and different
//   login_asid_own() -> u32            this process's audit session (0: unknown)
//   login_asid_peer(tok, pid) -> u32   a socket peer's, from the audit token read at connect
//                                      (trust.peer_read_token: val[6], audit_token_to_asid)
//
// The window checks the core on core.sock (client_core.odin): another login's is stopped
// (SIGTERM: its handover and save) and a core is launched from this login. The core checks the
// holder at connect (holder_client.odin): another login's is stopped (its sessions end) and a new
// holder starts; workspace.json restores the tabs (pi, Claude and Codex resume, shells start
// fresh). On Linux there is no audit session: both are 0, never "other".
//
// Test builds: DECKHAND_TEST_ASID=N makes N this process's session, and a process started under it
// notes N for its pid in the runtime dir (<run>/test-asid-<pid>, login_note), which is what a peer
// then reads for it. A peer with no note counts as this process's session. One scene runs a core
// under one N and a window under another (tests/scripts/other-login.sh).

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
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

login_asid_own :: proc() -> u32 {
	when TEST_HOOKS {
		if v := hook_env(.Test_Asid); v != "" {
			n, ok := strconv.parse_u64(v, 10)
			return ok && n <= u64(max(u32)) ? u32(n) : 0
		}
	}
	return login_asid_real()
}

login_asid_peer :: proc(tok: trust.Audit_Token, pid: i32) -> u32 {
	when TEST_HOOKS {
		if hook_env(.Test_Asid) != "" {
			run, why := sock_runtime_dir_why(context.temp_allocator)
			if why == "" {
				if b, err := os.read_entire_file(login_note_path(run, pid), context.temp_allocator); err == nil {
					n, ok := strconv.parse_u64(strings.trim_space(string(b)), 10)
					if ok && n <= u64(max(u32)) do return u32(n)
				}
			}
			return login_asid_own()
		}
	}
	when ODIN_OS == .Darwin {
		return tok.val[6]
	} else {
		return 0
	}
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
	}

	// getaudit_addr on oneself needs no privilege.
	@(private = "file")
	login_asid_real :: proc() -> u32 {
		ai: Auditinfo_Addr
		if login_getaudit_addr(&ai, size_of(ai)) != 0 do return 0
		return u32(ai.asid)
	}
} else {
	@(private = "file")
	login_asid_real :: proc() -> u32 {return 0}
}

// holder_client_start found a holder of ours from another login (holder_connect's Other_Login):
// stopped (SIGTERM, then SIGKILL: holder_stop_pid, only while pid is still that holder), its
// sessions with it, and its socket removed; the caller then starts a new holder in this login and
// the tabs restore from workspace.json. The user is told once a window shows it.
holder_replace_other_login :: proc(pid: i32, path: string) {
	start := holder_pid_start(pid)
	if start == 0 || !strings.has_suffix(holder_pid_exe(pid), "/" + HOLDER_BIN) {
		log_ln("Deckhand: session holder: the one from another login (pid", pid, ") is gone")
		sock_unlink(path)
		return
	}
	n := holder_children(pid)
	log_ln("Deckhand: session holder: stopping the one from another login (pid", pid, ",", n, "sessions)")
	holder_stop_pid(pid, start)
	sock_unlink(path)
	if autotest_active do fmt.printfln("[autotest] holder: replaced one from another login (pid %d, %d sessions)", pid, n)
	window_toast_shown(login_holder_replaced_text(n))
}

login_holder_replaced_text :: proc(sessions: int) -> string {
	if sessions <= 0 do return "Deckhand's session holder was from an earlier login, so a new one replaced it."
	return fmt.tprintf("Deckhand's session holder was from an earlier login, so a new one replaced it: %d %s here (pi, Claude and Codex resume their conversations; shells start fresh).", sessions, sessions == 1 ? "session restarts" : "sessions restart")
}
