#+build linux
package core

// Starting a separate core on Linux, and its install (docs/plans/background-core.md §8.4, §10.4
// M6-L1, M6-L2). There is no launchd: the core runs as the systemd user unit deckhand-core.service
// (systemd_unit.odin) when `deckhand-core-serve install` wrote it for the default data dir, else
// (no unit, no user manager, test mode, another data dir, a handover's successor) it is spawned
// directly in its own session (setsid; holder_launch_direct), its output in <run>/core.log, and
// is reparented once its launcher exits. The arguments are launchd_darwin.odin's core_launch's.
//
// The install: <data>/core/<version>-<sha12>/deckhand-core-serve (version "dev" until a release
// carries one, M6-L4; sha12 of the binary), made current as on macOS (core_make_current), then
// the unit (its ExecStart is core/current's binary), `systemctl --user daemon-reload`, and the
// linger check. No sudo, ever: enabling linger is the user's own choice (`linger --enable`, or
// the command shown).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"

core_launch :: proc(bin, run, data: string, from_tab := false, secret := "") -> (pid: i32, ok: bool, why: string) {
	// a handover's successor takes its secret on a pipe: always direct (M6-L3 moves it to systemd-run)
	if secret == "" && !autotest_active && systemd_unit_ours(data) {
		out, st := run_group(systemd_argv(.Start), 20 * time.Second, merge_stderr = true)
		if st == .Ok do return 0, true, ""
		fmt.eprintfln("Deckhand: background core: systemctl --user start %s failed (%v: %s): starting it directly", SYSTEMD_UNIT, st, strings.trim_space(out))
	}
	ours, _ := os.environ(context.temp_allocator)
	return holder_launch_direct(bin, run, data, core_launch_env(ours, from_tab), "serve", secret)
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
core_install_linux :: proc(exe, data: string) -> (serve: string, note: string, ok: bool) {
	src, rerr := os.read_entire_file(exe, context.temp_allocator)
	if rerr != nil do return "", fmt.tprintf("cannot read %s: %v", exe, rerr), false
	sum := holder_sha256(src)
	v := core_version()
	if v == "" do v = "dev"
	key := fmt.tprintf("%s-%s", v, sum[:12])
	vdir := core_versions_dir(data)
	dir := fmt.tprintf("%s/%s", vdir, key)
	dest := fmt.tprintf("%s/%s", dir, CORE_SERVE_BIN)
	if holder_sha256_file(dest) != sum {
		if w := file_install(dest, src, {.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH}); w != "" do return "", w, false
	}
	if w := core_make_current(vdir, key); w != "" do return "", w, false
	core_collect(vdir, core_in_use())
	serve = strings.clone(dest)

	home := data_home(TEST_HOOKS, context.temp_allocator)
	if data != data_dir_under(home, context.temp_allocator) do return serve, "not the default data dir: no systemd unit (the core is started directly)", true
	run := runtime_dir_linux(data)
	if run == "" do return serve, "no runtime dir: no systemd unit", true
	text, tok := systemd_unit_text(fmt.tprintf("%s/%s/%s", vdir, CORE_CURRENT, CORE_SERVE_BIN), run, data)
	if !tok do return serve, fmt.tprintf("a path cannot go in a systemd unit (%s, %s): no unit", run, data), true
	unit := systemd_unit_path()
	if w := file_install(unit, transmute([]u8)text, {.IRUSR, .IWUSR, .IRGRP, .IROTH}); w != "" do return serve, w, false
	notes: [dynamic]string
	notes.allocator = context.temp_allocator
	if out, st := run_group(systemd_argv(.Reload), 20 * time.Second, merge_stderr = true); st != .Ok {
		append(&notes, fmt.tprintf("no systemd user manager (systemctl --user daemon-reload: %v %s): the core is started directly", st, strings.trim_space(out)))
	}
	if linger_check() == .Off {
		append(&notes, fmt.tprintf("linger is off: jobs on this machine stop when you log out of it. To keep them running: %s", LINGER_COMMAND))
	}
	return serve, strings.join(notes[:], "; ", context.temp_allocator), true
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
