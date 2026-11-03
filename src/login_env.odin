package main

// pi-desk started from the Dock or Finder gets launchd's environment: PATH is
// /usr/bin:/bin:/usr/sbin:/sbin, and whatever the user's interactive shell
// setup adds is missing (Homebrew's `brew shellenv` in ~/.zshrc, nvm, a
// system rc that resets PATH in every login shell unless a flag it exports is
// set, as nix-darwin's does). `$SHELL -l -c 'exec pi'` then finds no pi.
//
// So at startup, before any thread or child, such a launch takes the
// environment an interactive login shell has (`$SHELL -i -l -c`, stdin
// /dev/null, a session of its own, 4 s at most), as a terminal
// would have given it: VS Code does the same. Every child (pi tabs, shells,
// jobs, git, the reload probe) inherits it. When that fails, PATH gains the
// usual install folders that exist. Started from a terminal, nothing changes.
// The values are never printed or logged (an rc file may export secrets).

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"

LOGIN_ENV_MARK :: "__pi_desk_env_7f3a9c__"
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

// The "K=V" entries between the markers of the shell's output (rc-file noise
// before and after ignored), without its session variables or pi-desk's own
// PI_DESK_* switches. ok: a PATH among
// them. Temp-allocated.
login_env_parse :: proc(out: string) -> (vars: []string, ok: bool) {
	i := strings.index(out, LOGIN_ENV_MARK)
	if i < 0 do return
	rest := out[i + len(LOGIN_ENV_MARK):]
	j := strings.index(rest, LOGIN_ENV_MARK)
	if j < 0 do return
	skip := LOGIN_ENV_SKIP
	list := make([dynamic]string, context.temp_allocator)
	for e in strings.split(rest[:j], "\x00", context.temp_allocator) {
		k, eq, _ := strings.partition(e, "=")
		if k == "" || eq == "" || slice.contains(skip[:], k) do continue
		if strings.has_prefix(k, "PI_DESK_") do continue // pi-desk's own switches (PI_DESK_SCRIPT: test mode)
		if k == "PATH" do ok = true
		append(&list, e)
	}
	return list[:], ok
}

// The environment of `shell -i -l -c`, as `env -0` prints it between markers.
login_env_ask :: proc(shell: string, timeout: time.Duration) -> (vars: []string, ok: bool) {
	cmd := fmt.tprintf(`printf '%%s' '%s'; /usr/bin/env -0; printf '%%s' '%s'`, LOGIN_ENV_MARK, LOGIN_ENV_MARK)
	out, run_ok := login_env_run({shell, "-i", "-l", "-c", cmd}, timeout)
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
login_env_run :: proc(argv: []string, timeout: time.Duration) -> (out: string, ok: bool) {
	cargv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for a, i in argv do cargv[i] = strings.clone_to_cstring(a, context.temp_allocator)
	pipe_out: [2]posix.FD
	if posix.pipe(&pipe_out) != .OK do return
	defer posix.close(pipe_out[0])
	posix.fcntl(pipe_out[0], .SETFD, i32(posix.FD_CLOEXEC))
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
	err := posix.posix_spawnp(&pid, cargv[0], &fa, &attr, raw_data(cargv), posix.environ)
	posix.close(pipe_out[1])
	if err != .NONE do return
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
		if !exited && posix.waitpid(pid, &wstatus, {.NOHANG}) == pid do exited = true
		if exited && (!open || login_env_complete(strings.to_string(b))) do return strings.to_string(b), true
		if time.tick_now()._nsec > deadline do break
	}
	// timed out (or too much output): the session's group, at once
	posix.killpg(pid, .SIGKILL)
	if !exited do posix.waitpid(pid, &wstatus, {})
	return "", false
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

// Where pi and its runtimes usually are. PI_DESK_PATH_DIRS replaces the list
// (tests: never the machine's real /opt/homebrew/bin).
login_env_dirs :: proc(home: string) -> []string {
	if v, found := os.lookup_env("PI_DESK_PATH_DIRS", context.temp_allocator); found {
		return strings.split(v, ":", context.temp_allocator)
	}
	dirs := make([dynamic]string, context.temp_allocator)
	append(&dirs, "/opt/homebrew/bin", "/usr/local/bin")
	if home != "" {
		for d in ([?]string{".local/bin", ".npm-global/bin", ".volta/bin", ".bun/bin"}) {
			append(&dirs, fmt.tprintf("%s/%s", strings.trim_right(home, "/"), d))
		}
	}
	return dirs[:]
}

// Sets this process's environment when PATH is launchd's (see the top).
// Call before any thread starts (setenv is not thread-safe).
login_env_fix :: proc(shell: string, dirs: []string, timeout: time.Duration) -> Login_Env_Result {
	if !path_is_bare(os.get_env("PATH", context.temp_allocator)) do return .Kept
	if vars, ok := login_env_ask(shell, timeout); ok {
		for e in vars {
			k, _, v := strings.partition(e, "=")
			os.set_env(k, v)
		}
		if !path_is_bare(os.get_env("PATH", context.temp_allocator)) do return .Shell
	}
	os.set_env("PATH", login_env_with_dirs(os.get_env("PATH", context.temp_allocator), dirs))
	return .Fallback
}

// main's call: the user's shell, the usual folders.
login_env_startup :: proc() {
	shell := os.get_env("SHELL", context.temp_allocator)
	if shell == "" do shell = "/bin/zsh"
	_ = login_env_fix(shell, login_env_dirs(os.get_env("HOME", context.temp_allocator)), LOGIN_ENV_TIMEOUT)
	free_all(context.temp_allocator)
}
