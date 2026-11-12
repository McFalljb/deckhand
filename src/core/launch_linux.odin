#+build linux
package core

// Starting a separate core on Linux, and its install (docs/plans/background-core.md §8.4, §10.4
// M6-L1, M6-L2). There is no launchd: the core runs as the systemd user unit deckhand-core.service
// (systemd_unit.odin) when `deckhand-core-serve install` wrote it for the default data dir, else
// (no unit, no user manager, test mode, another data dir, a handover's successor) it is spawned
// directly in its own session (setsid; holder_launch_direct), its output in <run>/core.log, and
// is reparented once its launcher exits. The arguments are launchd_darwin.odin's core_launch's.
//
// The session holder (M6-L3) and a core started directly each run in a transient scope of their
// own (systemd_scope_argv: deckhand-holder-<rand>.scope, deckhand-core-<rand>.scope), so stopping
// the core's unit never reaches the sessions, and a handover's successor is tracked by systemd.
// No user manager, or a scope that never runs the binary: spawned directly, with a warning. Test
// mode spawns directly unless DECKHAND_HOLDER_SYSTEMD=1.
//
// The install: <data>/core/<version>-<sha12>/deckhand-core-serve, with the holder, the CLI
// (deckhand) and the integrations (pi/, claude-code/) found beside it (the release tarball's
// layout, scripts/pack-linux.sh; version: a release build's -define, else "dev"; sha12 of the
// serve and holder pair), made current as on macOS (core_make_current), then
// the unit (its ExecStart is core/current's binary), `systemctl --user daemon-reload`, and the
// linger check. No sudo, ever: enabling linger is the user's own choice (`linger --enable`, or
// the command shown).

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

core_launch :: proc(bin, run, data: string, from_tab := false, secret := "") -> (pid: i32, ok: bool, why: string) {
	// a running core's handover (secret or not) or Use previous: bin in a scope of its own
	// (systemd_start_wanted, scope_launch). 5 s: within connect's 15 s, with retries
	current := core_serve_of(data, CORE_CURRENT)
	if systemd_start_wanted(real_path(bin), real_path(current), core_separate, autotest_active, systemd_unit_ours(data), core_use_previous_serve(data) != "") {
		out, st := run_group(systemd_argv(.Start), 5 * time.Second, merge_stderr = true)
		if st == .Ok do return 0, true, ""
		log_fln("Deckhand: background core: systemctl --user start %s failed (%v: %s): starting it directly", SYSTEMD_UNIT, st, strings.trim_space(out))
	}
	ours, _ := os.environ(context.temp_allocator)
	return scope_launch(bin, run, data, core_launch_env(ours, from_tab), "serve", secret)
}

// Starts a session holder for run and data, running bin (holder_install), with env (nil = this
// process's), in a scope of its own. pid: the holder's.
holder_launch :: proc(bin, run, data: string, env: []string) -> (pid: i32, ok: bool, why: string) {
	if len(run) + RUNTIME_HOLDER_NEED > SUN_PATH_MAX {
		return 0, false, fmt.tprintf("the runtime dir %s is too long for the session holder's socket (sun_path is %d bytes)", run, SUN_PATH_MAX + 1)
	}
	return scope_launch(bin, run, data, env, "hold", "")
}

SCOPE_WAIT :: 3 * time.Second // systemd-run has made the scope and exec'd bin

// holder_launch_direct, wrapped in a transient scope when systemd_scope_wanted (mode "hold": the
// holder; "serve": a core). The scope's launch is ours only once /proc/<pid>/exe is bin: until then
// it is waited for here, and on failure (systemd-run exited, or never exec'd bin within SCOPE_WAIT,
// then killed: never two) bin is spawned directly.
@(private = "file")
scope_launch :: proc(bin, run, data: string, env: []string, mode, secret: string) -> (pid: i32, ok: bool, why: string) {
	if !systemd_scope_wanted(autotest_active, hook_env(.Holder_Systemd) == "1", hook_env(.Holder_Direct) == "1") || !os.is_file(SYSTEMD_RUN) {
		return holder_launch_direct(bin, run, data, env, mode, secret)
	}
	if !systemd_scope_args_ok({bin, run, data}) {
		log_fln("Deckhand: %s: a '$' in %s, %s or %s (systemd-run would expand it): started directly, outside a systemd scope, so stopping the core's service can end the session holder and its sessions", mode == "serve" ? "background core" : "session holder", bin, run, data)
		return holder_launch_direct(bin, run, data, env, mode, secret)
	}
	r: [4]u8
	crypto.rand_bytes(r[:])
	unit := fmt.tprintf("deckhand-%s-%02x%02x%02x%02x", mode == "serve" ? "core" : "holder", r[0], r[1], r[2], r[3])
	p, sok, swhy := holder_launch_direct(bin, run, data, env, mode, secret, systemd_scope_argv(unit), reap = false)
	if sok {
		want := real_path(bin)
		deadline := time.tick_add(time.tick_now(), SCOPE_WAIT)
		for {
			st: i32
			if posix.waitpid(posix.pid_t(p), &st, {.NOHANG}) == posix.pid_t(p) {
				swhy = fmt.tprintf("systemd-run exited (status %d)", st)
				break
			}
			if want != "" && real_path(fmt.tprintf("/proc/%d/exe", p)) == want {
				holder_reap_later(p)
				return p, true, ""
			}
			if time.tick_diff(time.tick_now(), deadline) <= 0 {
				// still ours and unreaped (a zombie at worst): never a reused pid
				posix.kill(posix.pid_t(p), .SIGKILL)
				for posix.waitpid(posix.pid_t(p), &st, {}) < 0 && posix.errno() == .EINTR {}
				swhy = fmt.tprintf("it did not run %s within %v", bin, SCOPE_WAIT)
				break
			}
			time.sleep(10 * time.Millisecond)
		}
	}
	log_fln("Deckhand: %s: the systemd scope %s failed (%s): starting it directly, outside a scope, so stopping the core's service can end the session holder and its sessions", mode == "serve" ? "background core" : "session holder", unit, swhy)
	return holder_launch_direct(bin, run, data, env, mode, secret)
}

// path with every link resolved ("" when it cannot be). Temp.
@(private = "file")
real_path :: proc(path: string) -> string {
	if path == "" do return ""
	r := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator), nil)
	if r == nil do return ""
	defer posix.free(r)
	return strings.clone(string(r), context.temp_allocator)
}

// ~/.config/systemd/user/deckhand-core.service ("" with no home). Temp.
systemd_unit_path :: proc() -> string {
	home := data_home(TEST_HOOKS, context.temp_allocator)
	if !strings.has_prefix(home, "/") do return ""
	return fmt.tprintf("%s/.config/systemd/user/%s", strings.trim_right(home, "/"), SYSTEMD_UNIT)
}

// The unit is there and data is the default data dir (the one the unit serves).
@(private = "file")
systemd_unit_ours :: proc(data: string) -> bool {
	home := data_home(TEST_HOOKS, context.temp_allocator)
	if !strings.has_prefix(home, "/") || data != data_dir_under(home, context.temp_allocator) do return false
	p := systemd_unit_path()
	return p != "" && os.is_file(p)
}

// `install --data DIR` on Linux: this binary into <data>/core/<key>/, made current, then the unit
// for the default data dir. serve: the installed copy. note: what the user should know ("" = none:
// the unit is loaded and linger is on).
// The session holder (deckhand-core) beside this binary goes with it, and the key's sha12 is then
// of the pair (core_pair_sum, as a Core.app's); without one, of this binary alone, and sessions
// stop with the core.
core_install_linux :: proc(exe, data: string) -> (serve: string, note: string, ok: bool) {
	src, rerr := os.read_entire_file(exe, context.temp_allocator)
	if rerr != nil do return "", fmt.tprintf("cannot read %s: %v", exe, rerr), false
	hpath := fmt.tprintf("%s/%s", filepath.dir(exe), HOLDER_BIN)
	hsrc, herr := os.read_entire_file(hpath, context.temp_allocator)
	sum := herr == nil ? core_pair_sum(filepath.dir(exe)) : holder_sha256(src)
	if sum == "" do return "", fmt.tprintf("cannot read %s and %s", exe, hpath), false
	notes: [dynamic]string
	notes.allocator = context.temp_allocator
	if herr != nil do append(&notes, fmt.tprintf("no session holder beside it (%s): sessions stop when the core does", hpath))
	v := core_version()
	if v == "" do v = "dev"
	key := fmt.tprintf("%s-%s", v, sum[:12])
	vdir := core_versions_dir(data)
	dir := fmt.tprintf("%s/%s", vdir, key)
	dest := fmt.tprintf("%s/%s", dir, CORE_SERVE_BIN)
	exec_mode :: posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}
	// the holder first: a dir with serve in it is a whole install
	if herr == nil {
		hdest := fmt.tprintf("%s/%s", dir, HOLDER_BIN)
		if holder_sha256_file(hdest) != holder_sha256(hsrc) {
			if w := file_install(hdest, hsrc, exec_mode); w != "" do return "", w, false
		}
	}
	// the CLI and the integrations beside this binary (the release tarball's), before serve too
	from := filepath.dir(exe)
	if cli, cerr := os.read_entire_file(fmt.tprintf("%s/%s", from, LINUX_CLI_BIN), context.temp_allocator); cerr == nil {
		cdest := fmt.tprintf("%s/%s", dir, LINUX_CLI_BIN)
		if holder_sha256_file(cdest) != holder_sha256(cli) {
			if w := file_install(cdest, cli, exec_mode); w != "" do return "", w, false
		}
	}
	for name in LINUX_INTEGRATIONS {
		if !os.is_dir(fmt.tprintf("%s/%s", from, name)) || os.exists(fmt.tprintf("%s/%s", dir, name)) do continue
		if w := tree_install(fmt.tprintf("%s/%s", from, name), dir, name); w != "" do return "", w, false
	}
	if holder_sha256_file(dest) != holder_sha256(src) {
		if w := file_install(dest, src, exec_mode); w != "" do return "", w, false
	}
	if w := core_make_current(vdir, key); w != "" do return "", w, false
	core_collect(vdir, core_in_use())
	serve = strings.clone(dest)

	home := data_home(TEST_HOOKS, context.temp_allocator)
	no_unit := ""
	run := runtime_dir_linux(data)
	text, tok := systemd_unit_text(fmt.tprintf("%s/%s/%s", vdir, CORE_CURRENT, CORE_SERVE_BIN), run, data)
	if data != data_dir_under(home, context.temp_allocator) {
		no_unit = "not the default data dir: no systemd unit (the core is started directly)"
	} else if run == "" {
		no_unit = "no runtime dir: no systemd unit"
	} else if !tok {
		no_unit = fmt.tprintf("a path cannot go in a systemd unit (%s, %s): no unit", run, data)
	}
	if no_unit != "" {
		append(&notes, no_unit)
		return serve, strings.join(notes[:], "; ", context.temp_allocator), true
	}
	unit := systemd_unit_path()
	if w := file_install(unit, transmute([]u8)text, {.IRUSR, .IWUSR, .IRGRP, .IROTH}); w != "" do return serve, w, false
	if out, st := run_group(systemd_argv(.Reload), 20 * time.Second, merge_stderr = true); st != .Ok {
		append(&notes, fmt.tprintf("no systemd user manager (systemctl --user daemon-reload: %v %s): the core is started directly", st, strings.trim_space(out)))
	}
	if linger_check() == .Off {
		append(&notes, fmt.tprintf("linger is off: jobs on this machine stop when you log out of it. To keep them running: %s", LINGER_COMMAND))
	}
	return serve, strings.join(notes[:], "; ", context.temp_allocator), true
}

// The CLI beside a Linux core (claude_cli_path), and the integrations' folders (pi_integration_dir,
// claude_plugin_dir), which install copies with it.
LINUX_CLI_BIN :: "deckhand"
LINUX_INTEGRATIONS := [?]string{"pi", "claude-code"}

// Copies the folder from to <dir>/<name>: cp -R into a new folder beside it, then renamed in.
// Links are copied as links (cp -R never follows them). "" = done, else why not.
@(private = "file")
tree_install :: proc(from, dir, name: string) -> string {
	if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil && !os.is_dir(dir) {
		return fmt.tprintf("cannot make %s: %v", dir, err)
	}
	tmp := fmt.tprintf("%s/.%s.%d.tmp", dir, name, posix.getpid())
	remove_tree(tmp) // ours from an earlier try (the pid in the name)
	if out, st := run_group({"/bin/cp", "-R", "--", from, tmp}, 60 * time.Second, merge_stderr = true); st != .Ok {
		remove_tree(tmp)
		return fmt.tprintf("cannot copy %s: %v %s", from, st, strings.trim_space(out))
	}
	if posix.rename(strings.clone_to_cstring(tmp, context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/%s", dir, name), context.temp_allocator)) != 0 {
		e := posix.errno()
		remove_tree(tmp)
		return fmt.tprintf("cannot install %s/%s: %s", dir, name, posix.strerror(e))
	}
	return ""
}

// Writes data to path atomically: a new file beside it (O_EXCL, no link followed), synced, then
// renamed over it. mode never has the group or world write bit. Missing dirs are made 0700.
// "" = done, else why not.
@(private = "file")
file_install :: proc(path: string, data: []u8, mode: posix.mode_t) -> string {
	dir := filepath.dir(path)
	if err := os.make_directory_all(dir, {.Read_User, .Write_User, .Execute_User}); err != nil && !os.is_dir(dir) {
		return fmt.tprintf("cannot make %s: %v", dir, err)
	}
	tmp := fmt.tprintf("%s/.%s.%d.tmp", dir, filepath.base(path), posix.getpid())
	ctmp := strings.clone_to_cstring(tmp, context.temp_allocator)
	posix.unlink(ctmp) // ours from an earlier try (the pid in the name)
	fd := posix.open(ctmp, {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return fmt.tprintf("cannot write %s: %s", tmp, posix.strerror(posix.errno()))
	rest := data
	for len(rest) > 0 {
		n := posix.write(fd, raw_data(rest), len(rest))
		if n < 0 && posix.errno() == .EINTR do continue
		if n <= 0 {
			posix.close(fd)
			posix.unlink(ctmp)
			return fmt.tprintf("cannot write %s: %s", tmp, posix.strerror(posix.errno()))
		}
		rest = rest[n:]
	}
	ok := posix.fchmod(fd, mode - {.IWGRP, .IWOTH}) == .OK && posix.fsync(fd) == .OK
	posix.close(fd)
	if !ok || posix.rename(ctmp, strings.clone_to_cstring(path, context.temp_allocator)) != 0 {
		e := posix.errno()
		posix.unlink(ctmp)
		return fmt.tprintf("cannot install %s: %s", path, posix.strerror(e))
	}
	return ""
}

// This user's linger, from logind (no logind, or no answer in 5 s: Unknown).
linger_check :: proc() -> Linger {
	out, st := run_group(linger_show_argv(u32(posix.getuid())), 5 * time.Second, merge_stderr = true)
	return linger_parse(out, st == .Ok)
}

// The user said yes to linger (M6-E's setup asks): `loginctl enable-linger` for this user, with no
// password prompt. polkit allows it or refuses; then the state, read again.
linger_enable :: proc() -> Linger {
	if linger_check() == .On do return .On
	run_group(linger_enable_argv(), 10 * time.Second, merge_stderr = true)
	return linger_check()
}

// What serve read at its start (the hello's machine.linger; serve.odin). Unknown in test mode.
linger_state: Linger
