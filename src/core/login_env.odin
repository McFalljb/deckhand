package core

// Deckhand started from the Dock, Finder, Spotlight or `open` gets launchd's
// environment, not the one a terminal gives: PATH is /usr/bin:/bin:/usr/sbin:/sbin
// or whatever launchd was configured with (a Nix profile's folders, say), and
// everything the user's interactive shell setup adds is missing (Homebrew's
// `brew shellenv` in ~/.zshrc, ~/.pi/agent/bin, nvm, AWS_PROFILE; a system rc
// that resets PATH in every login shell unless a flag it exports is set, as
// nix-darwin's does). A PATH that is not launchd's bare one proves nothing.
//
// So at startup, before any thread or child, a GUI launch (the parent is
// launchd, pid 1; or PATH is launchd's bare one) asks an interactive login
// shell for its environment (`$SHELL -i -l -c`, stdin /dev/null, a session of
// its own, 4 s at most), as VS Code does, and MERGES it in:
//   - the shell's values win, as in a terminal (the shell inherited the same
//     environment, so a value differs only where an rc file set it on purpose:
//     a 1Password SSH_AUTH_SOCK over launchd's); variables the shell did not
//     print are kept; the session's own (PWD, SHLVL, _) and DECKHAND_* never come;
//   - PATH is the shell's, in the shell's order (a terminal's order: rc files
//     put Homebrew and Nix first on purpose), then the inherited folders the
//     shell's PATH lacks, at the end; no folder twice.
// Every child (pi tabs, shells, jobs, git, the reload probe) inherits it.
// When the shell gives nothing, PATH gains the usual install folders that
// exist. Started from a terminal, nothing changes.
//
// Claude Code's session markers (claude_session_marker: CLAUDECODE,
// CLAUDE_CODE_CHILD_SESSION, CLAUDE_CODE_SESSION_ID, CLAUDE_PID…) are what a
// running claude sets in ITS children (code.claude.com/docs/en/env-vars).
// Deckhand started from a shell inside a Claude Code session (`open`, or a
// terminal there) would pass them to every tab: a Claude tab would start as
// that session's child (no transcript saved, "inherited
// CLAUDE_CODE_CHILD_SESSION marker"). So they leave this process's
// environment at startup, every launch, and never come from the shell
// either. Started from inside a Claude session (a marker only claude itself
// sets: login_env_from_claude), the parent's other Claude settings
// (claude_config_var: CLAUDE_CONFIG_DIR, CLAUDE_EFFORT…, which claude also
// passes on from its settings' `env`) are not taken as the user's: the login
// shell is asked (as for a GUI launch) with them left out, and only what it
// sets itself comes back. No answer from the shell (it failed or timed out):
// they stay, as inherited (only the markers go). ANTHROPIC_* always stay (pi
// and Atlas read them too). DECKHAND_GUI_LAUNCH=0 turns all this off (the
// markers still go).
//
// "Refresh shell environment" (Refresh_Shell_Env) asks again later, on a
// worker, with the environment Deckhand was started with, and merges the same
// way into an environment kept here for NEW tabs (child_base_env); the
// process's own is not changed after startup (setenv is not thread-safe),
// and running tabs keep theirs.
// The values are never printed or logged (an rc file may export secrets).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

LOGIN_ENV_MARK :: "__deckhand_env_7f3a9c__"
LOGIN_ENV_TIMEOUT :: 4 * time.Second

@(private = "file")
LAUNCHD_PATH :: [?]string{"/usr/bin", "/bin", "/usr/sbin", "/sbin"}
// the shell's own session, not the user's environment
@(private = "file")
LOGIN_ENV_SKIP :: [?]string{"PWD", "OLDPWD", "SHLVL", "_"}

Login_Env_Result :: enum {
	Kept, // PATH was not launchd's: started from a terminal
	Shell, // the login shell's environment
	Fallback, // the shell gave none (or a bare PATH): the install folders
}

// PATH as launchd gives a GUI app: only the system folders (or none).
path_is_bare :: proc(path: string) -> bool {
	system := LAUNCHD_PATH
	for d in strings.split(path, ":", context.temp_allocator) {
		if d != "" && !slice.contains(system[:], d) do return false
	}
	return true
}

// What a running Claude Code sets in the processes it starts (its Bash tool,
// hooks, MCP servers, IDE terminals; code.claude.com/docs/en/env-vars:
// "Set automatically", "Set by Claude Code, not by you"), and the ones seen
// in such an environment that only make sense there (the parent's binary,
// its entrypoint, whether it is attended): never a child's of deckhand.
@(private = "file")
CLAUDE_SESSION_MARKERS :: [?]string{
	"CLAUDECODE", // "Set to 1 in subprocesses Claude Code spawns"; IDE terminals too
	"CLAUDE_CODE_CHILD_SESSION", // a nested interactive claude is left out of --resume and history
	"CLAUDE_CODE_ENTRYPOINT",
	"CLAUDE_CODE_EXECPATH",
	"CLAUDE_PID", // "its own process ID in the subprocesses it spawns"
	"CLAUDE_CODE_SSE_PORT", // an IDE's connection
	"CLAUDE_CODE_BRIDGE_SESSION_ID", // Remote Control
	"CLAUDE_CODE_REMOTE_SESSION_ID", // a cloud session's id
	"CLAUDE_JOB_DIR", // a background session's folder
}
@(private = "file")
CLAUDE_SESSION_MARKER_PREFIXES :: [?]string{
	"CLAUDE_CODE_SESSION_", // _ID ("Set automatically to the current session ID"), _ATTENDED…; not SESSIONEND_…
	"CLAUDE_CODE_MESSAGING_", // _SOCKET, _TOKEN: "Each session exports its own … never one inherited"
}
// Only claude itself sets these (not an IDE's terminal, which sets CLAUDECODE):
// Deckhand was started from inside a Claude Code session.
@(private = "file")
CLAUDE_SESSION_PROOF :: [?]string{"CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID"}

// A Claude Code session marker (above): never passed to a child.
claude_session_marker :: proc(k: string) -> bool {
	names := CLAUDE_SESSION_MARKERS
	if slice.contains(names[:], k) do return true
	for p in CLAUDE_SESSION_MARKER_PREFIXES do if strings.has_prefix(k, p) do return true
	return false
}

// A Claude Code setting (CLAUDE_CONFIG_DIR, CLAUDE_EFFORT, CLAUDE_CODE_…): not a
// session marker. From inside a Claude session these are that session's (its
// launcher's, its settings' `env`), not the user's. ANTHROPIC_* are not: pi and
// Atlas read them too.
claude_config_var :: proc(k: string) -> bool {
	if claude_session_marker(k) do return false
	return strings.has_prefix(k, "CLAUDE_")
}

// The environment is a Claude Code session's child's (CLAUDE_SESSION_PROOF).
login_env_from_claude :: proc(env: []string) -> bool {
	proof := CLAUDE_SESSION_PROOF
	for k in proof do if _, found := env_lookup(env, k); found do return true // env-read-ok: k from the literal proof list
	return false
}

// env without Claude Code's session markers, and with config also without
// its other Claude settings (claude_config_var). Temp-allocated.
login_env_strip_claude :: proc(env: []string, config: bool) -> []string {
	out := make([dynamic]string, 0, len(env), context.temp_allocator)
	for e in env {
		k, _, _ := strings.partition(e, "=")
		if claude_session_marker(k) || (config && claude_config_var(k)) do continue
		append(&out, e)
	}
	return out[:]
}

// The "K=V" entries between the markers of the shell's output (rc-file noise
// before and after ignored), without its session variables or Deckhand's own
// DECKHAND_* switches. ok: a PATH among
// them. Temp-allocated.
login_env_parse :: proc(out: string) -> (vars: []string, ok: bool) {
	i := strings.index(out, LOGIN_ENV_MARK)
	if i < 0 do return
	rest := out[i + len(LOGIN_ENV_MARK):]
	j := strings.index(rest, LOGIN_ENV_MARK)
	if j < 0 do return
	list := make([dynamic]string, context.temp_allocator)
	for e in strings.split(rest[:j], "\x00", context.temp_allocator) {
		k, eq, _ := strings.partition(e, "=")
		if k == "" || eq == "" || login_env_skipped(k) do continue // DECKHAND_SCRIPT would be test mode
		if k == "PATH" do ok = true
		append(&list, e)
	}
	return list[:], ok
}

// What asks the shell (tests: a stub). env: the shell's environment (nil =
// this process's). Temp-allocated.
Login_Env_Probe :: #type proc(shell: string, timeout: time.Duration, env: []string) -> (vars: []string, ok: bool)

// The environment of `shell -i -l -c`, as `env -0` prints it between markers.
login_env_ask :: proc(shell: string, timeout: time.Duration, env: []string = nil) -> (vars: []string, ok: bool) {
	cmd := fmt.tprintf(`printf '%%s' '%s'; /usr/bin/env -0; printf '%%s' '%s'`, LOGIN_ENV_MARK, LOGIN_ENV_MARK)
	out, run_ok := login_env_run({shell, "-i", "-l", "-c", cmd}, timeout, env)
	if !run_ok do return
	return login_env_parse(out)
}

when ODIN_OS == .Darwin {
	@(private = "file")
	POSIX_SPAWN_SETSID :: 0x0400
} else {
	@(private = "file")
	POSIX_SPAWN_SETSID :: 0x0080 // glibc
}

// Runs the probe: in a session of its own (no controlling terminal: from a
// terminal, `zsh -i` would open /dev/tty from a background group and stop on
// SIGTTIN), stdin /dev/null, stderr nowhere. Done when the shell has exited
// and its output is complete (EOF, or the end marker: a process the rc file
// put in the background may hold the pipe; it is left alone). At the
// timeout: SIGKILL to the session's group (interactive shells ignore
// SIGTERM). ok: the shell exited in time (any status: an rc file's last
// command may fail; the markers tell whether the answer came).
login_env_run :: proc(argv: []string, timeout: time.Duration, env: []string = nil) -> (out: string, ok: bool) {
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	envp := posix.environ
	if env != nil {
		cenv := make([]cstring, len(env) + 1, context.temp_allocator)
		for e, i in env do cenv[i] = strings.clone_to_cstring(e, context.temp_allocator)
		envp = raw_data(cenv)
	}
	pipe_out: [2]posix.FD
	if posix.pipe(&pipe_out) != .OK do return
	defer posix.close(pipe_out[0])
	posix.fcntl(pipe_out[0], .SETFD, i32(posix.FD_CLOEXEC))
	posix.fcntl(pipe_out[1], .SETFD, i32(posix.FD_CLOEXEC)) // the dup2 into stdout clears it in the child
	null_fd := posix.open("/dev/null", {.RDWR, .CLOEXEC})
	defer if null_fd >= 0 do posix.close(null_fd)
	attr, fa: [512]u8 // opaque (a pointer on macOS, a struct elsewhere)
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_adddup2(&fa, i32(null_fd), 0)
	posix_spawn_file_actions_adddup2(&fa, i32(pipe_out[1]), 1)
	posix_spawn_file_actions_adddup2(&fa, i32(null_fd), 2)
	pid: posix.pid_t
	sync.rw_mutex_shared_lock(&fork_lock) // fork_lock, pty.odin
	err := posix.posix_spawnp(&pid, cargv[0], &fa, &attr, raw_data(cargv), envp)
	sync.rw_mutex_shared_unlock(&fork_lock)
	posix.close(pipe_out[1])
	if err != .NONE do return
	sync.lock(&login_probe.lock)
	login_probe.pid = pid // login_env_kill_probe (quit) kills its group
	sync.unlock(&login_probe.lock)
	b := strings.builder_make(context.temp_allocator)
	deadline := time.tick_now()._nsec + i64(timeout)
	buf: [16 << 10]u8
	open, exited := true, false
	wstatus: i32
	for {
		if open {
			pfd := [1]posix.pollfd{{fd = pipe_out[0], events = {.IN}}}
			if posix.poll(&pfd[0], 1, 20) > 0 {
				n := posix.read(pipe_out[0], &buf[0], len(buf))
				if n <= 0 do open = false
				else if strings.builder_len(b) + int(n) > LOGIN_ENV_CAP do break
				else do strings.write_bytes(&b, buf[:n])
			}
		} else {
			time.sleep(10 * time.Millisecond)
		}
		if !exited {
			sync.lock(&login_probe.lock) // reaped and forgotten together: never a reused pid killed
			if posix.waitpid(pid, &wstatus, {.NOHANG}) == pid {
				exited = true
				login_probe.pid = 0
			}
			sync.unlock(&login_probe.lock)
		}
		if exited && (!open || login_env_complete(strings.to_string(b))) do return strings.to_string(b), true
		if time.tick_now()._nsec > deadline do break
	}
	// timed out (or too much output): the session's group, at once
	sync.lock(&login_probe.lock)
	posix.killpg(pid, .SIGKILL)
	if !exited do posix.waitpid(pid, &wstatus, {})
	login_probe.pid = 0
	sync.unlock(&login_probe.lock)
	return "", false
}

// The probe running now (its session's group), for quitting mid-refresh.
@(private = "file")
login_probe: struct {
	lock: sync.Mutex,
	pid:  posix.pid_t, // 0 = none (or reaped)
}

// The probe's pid now (0 = none). Tests.
login_env_probe_pid :: proc() -> i32 {
	sync.lock(&login_probe.lock)
	defer sync.unlock(&login_probe.lock)
	return i32(login_probe.pid)
}

// Quitting (cleanup): a probe still waiting on an rc file goes with its whole
// session group now, not at the worker's timeout (an interactive shell left
// running otherwise). The worker then sees it exit and answers "no environment".
login_env_kill_probe :: proc() {
	sync.lock(&login_probe.lock)
	defer sync.unlock(&login_probe.lock)
	if login_probe.pid > 0 do posix.killpg(login_probe.pid, .SIGKILL)
}

@(private = "file")
LOGIN_ENV_CAP :: 4 << 20

// Both markers are in (the shell may have exited before its output is read).
@(private = "file")
login_env_complete :: proc(out: string) -> bool {
	i := strings.index(out, LOGIN_ENV_MARK)
	return i >= 0 && strings.contains(out[i + len(LOGIN_ENV_MARK):], LOGIN_ENV_MARK)
}

// path with those of dirs that exist and are not on it yet, in order.
login_env_with_dirs :: proc(path: string, dirs: []string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for d in strings.split(path, ":", context.temp_allocator) do if d != "" do append(&parts, d)
	for d in dirs {
		if d == "" || slice.contains(parts[:], d) || path_kind(d) != .Dir do continue
		append(&parts, d)
	}
	return strings.join(parts[:], ":", context.temp_allocator)
}

// Where pi and its runtimes usually are. DECKHAND_PATH_DIRS replaces the list
// (tests: never the machine's real /opt/homebrew/bin).
login_env_dirs :: proc(home: string) -> []string {
	if v, found := hook_lookup(.Path_Dirs); found {
		return strings.split(v, ":", context.temp_allocator)
	}
	dirs := make([dynamic]string, context.temp_allocator)
	if d := pi_agent_dir(); os.get_env("PI_CODING_AGENT_DIR", context.temp_allocator) != "" && strings.has_prefix(d, "/") {
		append(&dirs, fmt.tprintf("%s/bin", strings.trim_right(d, "/"))) // pi's managed install (moved: PI_CODING_AGENT_DIR, ~ expanded)
	}
	append(&dirs, "/opt/homebrew/bin", "/usr/local/bin")
	if home != "" {
		for d in ([?]string{".pi/agent/bin", ".local/bin", ".npm-global/bin", ".volta/bin", ".bun/bin"}) {
			append(&dirs, fmt.tprintf("%s/%s", strings.trim_right(home, "/"), d))
		}
	}
	return dirs[:]
}

// pi's official managed install, for when pi is not on PATH:
// $PI_CODING_AGENT_DIR/bin/pi, else ~/.pi/agent/bin/pi ("" = neither is an
// executable file). The tabs' command (PI_TAB_CMD) looks in the same places.
pi_managed_path :: proc() -> string {
	cands := make([dynamic]string, context.temp_allocator)
	if d := pi_agent_dir(); os.get_env("PI_CODING_AGENT_DIR", context.temp_allocator) != "" && strings.has_prefix(d, "/") {
		append(&cands, fmt.tprintf("%s/bin/pi", strings.trim_right(d, "/"))) // PI_CODING_AGENT_DIR, ~ expanded
	}
	if h := os.get_env("HOME", context.temp_allocator); strings.has_prefix(h, "/") {
		append(&cands, fmt.tprintf("%s/.pi/agent/bin/pi", strings.trim_right(h, "/")))
	}
	for p in cands {
		if path_kind(p) == .File && posix.access(strings.clone_to_cstring(p, context.temp_allocator), {.X_OK}) == .OK do return p
	}
	return ""
}

// The value of K in a "K=V" list ("", false: none).
env_lookup :: proc(env: []string, key: string) -> (string, bool) {
	for e in env {
		k, eq, v := strings.partition(e, "=")
		if eq != "" && k == key do return v, true
	}
	return "", false
}

// PATH from the shell's (its order) and the inherited one (its folders the
// shell lacks, after); empty entries and repeats dropped. Temp-allocated.
login_env_merge_path :: proc(shell_path, inherited_path: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for p in ([?]string{shell_path, inherited_path}) {
		for d in strings.split(p, ":", context.temp_allocator) {
			if d != "" && !slice.contains(parts[:], d) do append(&parts, d)
		}
	}
	return strings.join(parts[:], ":", context.temp_allocator)
}

// The shell's session variables and Deckhand's own switches: never taken from it.
@(private = "file")
login_env_skipped :: proc(k: string) -> bool {
	skip := LOGIN_ENV_SKIP
	// an explicit list (env_names.odin), not the DECKHAND_ prefix: the user's own
	// DECKHAND_SIGN_IDENTITY and the like come from the shell like any variable
	return slice.contains(skip[:], k) || env_desk_owned(k)
}

// The environment a GUI launch gives its children: the inherited one merged
// with the shell's (see the top), or with no answer from the shell (or a
// bare PATH in it), the inherited one with the install folders that exist on
// PATH. Temp-allocated.
login_env_compose :: proc(inherited, shell: []string, shell_ok: bool, dirs: []string) -> (env: []string, result: Login_Env_Result) {
	out := make([dynamic]string, context.temp_allocator)
	path, _ := env_lookup(inherited, "PATH")
	result = .Fallback
	for e in inherited {
		k, _, _ := strings.partition(e, "=")
		if k == "PATH" || claude_session_marker(k) do continue
		if shell_ok && !login_env_skipped(k) {
			if v, have := env_lookup(shell, k); have { // env-read-ok: merging the login shell env by key
				append(&out, fmt.tprintf("%s=%s", k, v)) // the shell's wins, as in a terminal
				continue
			}
		}
		append(&out, e)
	}
	if shell_ok {
		for e in shell {
			k, eq, _ := strings.partition(e, "=")
			if eq == "" || k == "PATH" || login_env_skipped(k) || claude_session_marker(k) do continue
			if _, have := env_lookup(inherited, k); have do continue // replaced above (env-read-ok: merging by key)
			if _, dup := env_lookup(out[:], k); dup do continue // env-read-ok: merging by key
			append(&out, e)
		}
		sp, _ := env_lookup(shell, "PATH")
		if !path_is_bare(sp) do result = .Shell
		path = login_env_merge_path(sp, path)
	}
	if result == .Fallback do path = login_env_with_dirs(path, dirs)
	append(&out, fmt.tprintf("PATH=%s", path))
	return out[:], result
}

// A GUI launch (see the top): DECKHAND_GUI_LAUNCH=1 or 0 says (tests, or to
// turn the import off); else the parent is launchd (LaunchServices: Dock,
// Finder, Spotlight, `open`), or PATH is launchd's bare one, or Deckhand was
// started from inside a Claude Code session (from_claude: its environment is
// that session's, not a terminal's). Test mode (DECKHAND_SCRIPT) never is
// without DECKHAND_GUI_LAUNCH=1: scenes never ask the real shell.
login_env_gui_launch :: proc(ppid: int, path, override: string, test_mode := false, from_claude := false) -> bool {
	switch override {
	case "1": return true
	case "0": return false
	}
	if test_mode do return false
	return ppid == 1 || path_is_bare(path) || from_claude
}

// The shell asked and its answer merged into launch (an environment without
// the markers), see the top: from inside a Claude session (from_claude) the
// shell is started without the parent's Claude settings, and with an answer
// they are left out of the result too; with none, launch as it is (and the
// fallback folders). ok: the shell answered. Temp-allocated.
login_env_shell_merge :: proc(launch: []string, from_claude: bool, shell: string, timeout: time.Duration, probe: Login_Env_Probe, dirs: []string) -> (env: []string, result: Login_Env_Result, ok: bool) {
	ask := login_env_strip_claude(launch, from_claude)
	vars: []string
	vars, ok = probe(shell, timeout, ask)
	if ok {
		env, result = login_env_compose(ask, vars, true, dirs)
	} else {
		env, result = login_env_compose(launch, nil, false, dirs)
	}
	return
}

// Sets this process's environment: Claude Code's session markers out (every
// launch); for a GUI launch (see the top), merged with what probe gets from
// the shell (login_env_shell_merge). Call before
// any thread starts (setenv is not thread-safe).
login_env_fix :: proc(gui: bool, shell: string, dirs: []string, timeout: time.Duration, probe: Login_Env_Probe = login_env_ask) -> Login_Env_Result {
	inherited, _ := os.environ(context.temp_allocator)
	env := login_env_strip_claude(inherited, false)
	result := Login_Env_Result.Kept
	if gui do env, result, _ = login_env_shell_merge(env, login_env_from_claude(inherited), shell, timeout, probe, dirs)
	for e in inherited {
		k, _, _ := strings.partition(e, "=")
		if _, keep := env_lookup(env, k); !keep do posix.unsetenv(strings.clone_to_cstring(k, context.temp_allocator)) // env-read-ok: merging by key
	}
	for e in env {
		k, _, v := strings.partition(e, "=")
		if cur, have := env_lookup(inherited, k); have && cur == v do continue // env-read-ok: merging by key
		// libc's setenv: os.set_env, reached from deckhand-core-serve (login_env_adopt), crashes
		// Odin's LLVM backend at -o:speed ("Unknown handled type: i32 -> i32"; dev-2026-09)
		posix.setenv(strings.clone_to_cstring(k, context.temp_allocator), strings.clone_to_cstring(v, context.temp_allocator), true)
	}
	return result
}

// What the startup kept for a later refresh, and the refreshed environment.
// Main thread only, except `running` (the worker's flag).
login_env: struct {
	gui:      bool,
	from_claude: bool, // started from inside a Claude Code session (login_env_from_claude)
	launch:   []string, // the environment Deckhand was started with (heap; a GUI launch only)
	children: []string, // after a refresh: what new tabs get (heap); nil = this process's
	running:  bool,
}

// main's call: the user's shell, the usual folders. no_window: a process no terminal started
// either (`connect`, run by another machine's ssh: login_env_adopt), taken as launchd's child.
login_env_startup :: proc(no_window := false) {
	path := os.get_env("PATH", context.temp_allocator)
	test_mode := hook_env(.Script) != ""
	env, _ := os.environ(context.temp_allocator)
	ppid := int(posix.getppid())
	if no_window do ppid = 1
	gui := login_env_gui_launch(ppid, path, login_env_gui_switch(), test_mode, login_env_from_claude(env))
	login_env.gui = gui
	login_env.from_claude = login_env_from_claude(env)
	if gui do login_env.launch = env_clone(login_env_strip_claude(env, false)) // a refresh asks with it (markers out)
	_ = login_env_fix(gui, login_shell(), login_env_dirs(os.get_env("HOME", context.temp_allocator)), LOGIN_ENV_TIMEOUT)
	free_all(context.temp_allocator)
}

// A separate core's environment (core_launch: launchd_darwin.odin, launch_linux.odin): env without
// the names Deckhand sets for its tabs, jobs and control callers, under either name
// (env_tab_dropped: the same scrub a tab's own environment gets). Temp allocator.
core_launch_env :: proc(env: []string, from_tab := false) -> []string {
	out := make([dynamic]string, 0, len(env), context.temp_allocator)
	for e in login_env_strip_claude(env, from_tab) do if !env_tab_dropped(env_key(e)) do append(&out, e)
	return out[:]
}

// A separate core (serve): its environment is its window's, merged with the login shell's at that
// window's launch, so it asks the shell only for a refresh: when that window was a GUI launch (it
// says so with DECKHAND_GUI_LAUNCH=1: core_launch), or when its own launch passes the same test
// (launchd starts it, as it starts a Dock launch). Its tabs never get that name (env_tab_dropped).
//
// no_window: a core that never has a window to inherit from (Linux: systemd's environment, or
// connect's over ssh; #135) is taken as launchd's child, and so asks the login shell at its
// start too, exactly as a window's launch does (login_env_fix: the same merge, skip list and
// timeout), unless it inherited a core's environment already merged (inherited: a handover's
// successor) or DECKHAND_GUI_LAUNCH=0 or test mode says no. Call before any thread starts.
login_env_adopt :: proc(no_window := false, inherited := false, probe: Login_Env_Probe = login_env_ask) {
	env, _ := os.environ(context.temp_allocator)
	login_env.from_claude = login_env_from_claude(env)
	ppid := int(posix.getppid())
	if no_window do ppid = 1 // as launchd's child: never a terminal's
	login_env.gui = login_env_gui_launch(ppid, os.get_env("PATH", context.temp_allocator), login_env_gui_switch(), hook_env(.Script) != "", login_env.from_claude)
	if login_env.gui do login_env.launch = env_clone(login_env_strip_claude(env, false)) // a refresh asks with it
	if login_env_adopt_asks(no_window, inherited, login_env.gui) {
		_ = login_env_fix(true, login_shell(), login_env_dirs(os.get_env("HOME", context.temp_allocator)), LOGIN_ENV_TIMEOUT, probe)
	}
}

// Whether a separate core asks the login shell at its start (login_env_adopt).
login_env_adopt_asks :: proc(no_window, inherited, gui: bool) -> bool {
	return no_window && !inherited && gui
}

// The environment new child processes start from: the refreshed one, else
// this process's. Temp-allocated (the strings: shared, do not free).
// Never Claude Code's session markers (they left this process's environment
// at startup; checked again here, whatever the base).
child_base_env :: proc() -> []string {
	env := login_env.children
	if env == nil do env, _ = os.environ(context.temp_allocator)
	return login_env_strip_claude(env, false)
}

@(private = "file")
env_clone :: proc(env: []string) -> []string {
	h := runtime.heap_allocator() // made on the worker, freed on the main thread
	out := make([]string, len(env), h)
	for e, i in env do out[i] = strings.clone(e, h)
	return out
}

@(private = "file")
env_free :: proc(env: []string) {
	h := runtime.heap_allocator()
	for e in env do delete(e, h)
	delete(env, h)
}

// The refresh's worker: what it asks with, and its answer.
Login_Env_Job :: struct {
	request_id: u64,
	shell:      string,
	launch:     []string,
	from_claude: bool,
	dirs:       []string,
	probe:      Login_Env_Probe,
	timeout:    time.Duration,
}

// The "Refresh shell environment" command's answer timeout (tests raise it: a fake shell's start
// under load can take longer than a real shell's on a quiet machine)
login_env_refresh_timeout := LOGIN_ENV_TIMEOUT

// Starts a refresh on a worker (false: one is running already). A terminal
// launch has nothing to refresh: the caller says so.
login_env_refresh_start :: proc(request_id: u64, probe: Login_Env_Probe = login_env_ask, timeout := LOGIN_ENV_TIMEOUT) -> bool {
	if login_env.running do return false
	login_env.running = true
	job := new(Login_Env_Job, runtime.heap_allocator())
	job^ = {
		request_id = request_id,
		shell      = strings.clone(login_shell(), runtime.heap_allocator()),
		launch     = env_clone(login_env.launch),
		from_claude = login_env.from_claude,
		dirs       = env_clone(login_env_dirs(os.get_env("HOME", context.temp_allocator))),
		probe      = probe,
		timeout    = timeout,
	}
	if thread.create_and_start_with_poly_data(job, login_env_refresh_worker, self_cleanup = true) == nil {
		login_env_job_free(job)
		login_env.running = false
		return false
	}
	return true
}

@(private = "file")
login_env_job_free :: proc(job: ^Login_Env_Job) {
	h := runtime.heap_allocator()
	delete(job.shell, h)
	env_free(job.launch)
	env_free(job.dirs)
	free(job, h)
}

@(private = "file")
login_env_refresh_worker :: proc(job: ^Login_Env_Job) {
	defer free_all(context.temp_allocator)
	merged, _, ok := login_env_shell_merge(job.launch, job.from_claude, job.shell, job.timeout, job.probe, job.dirs)
	env: []string
	if ok do env = env_clone(merged)
	inbox_submit(Refresh_Shell_Env_Done{request_id = job.request_id, ok = ok, env = env}, {kind = .Internal})
	login_env_job_free(job)
	if platform.wake != nil do platform.wake()
}

// The worker's answer (main thread): new tabs get env from now on.
login_env_refresh_done :: proc(ok: bool, env: []string) {
	login_env.running = false
	if !ok do return
	if login_env.children != nil do env_free(login_env.children)
	login_env.children = env
}



// DECKHAND_GUI_LAUNCH, else its old name PI_DESK_GUI_LAUNCH (env_names.odin).
login_env_gui_switch :: proc() -> string {
	if v, ok := os.lookup_env("DECKHAND_GUI_LAUNCH", context.temp_allocator); ok do return v
	return os.get_env("PI_DESK_GUI_LAUNCH", context.temp_allocator)
}
