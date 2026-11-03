package main

// login_env.odin: a Dock launch takes the interactive login shell's
// environment. Fake shells are tiny /bin/sh scripts in a temp folder.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

@(private = "file")
le_dir :: proc(tag: string) -> string {
	tmp := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if tmp == "" do tmp = "/tmp"
	d := fmt.tprintf("%s/pd-le-%s-%d", tmp, tag, time.now()._nsec)
	os.make_directory_all(d)
	return d
}

// A fake shell: checks it was asked as `-i -l -c CMD`, prints noise around
// CMD's output, and runs CMD with BIN first on PATH (as ~/.zshrc would).
@(private = "file")
le_fake_shell :: proc(dir, bin: string, body := "") -> string {
	sh := fmt.tprintf("%s/fakesh", dir)
	script := body
	if script == "" do script = fmt.tprintf(
		"#!/bin/sh\n" +
		"[ \"$1 $2 $3\" = \"-i -l -c\" ] || {{ echo \"bad args: $*\"; exit 2; }}\n" +
		"echo 'rc noise: before'\n" +
		"export PATH=\"%s:$PATH\" LE_TEST_FROM_RC=yes\n" +
		"/bin/sh -c \"$4\"\n" +
		"echo 'rc noise: after'\n",
		bin,
	)
	_ = os.write_entire_file(sh, transmute([]u8)script)
	_ = os.chmod(sh, os.perm_number(0o755))
	return sh
}

@(test)
login_env_path_is_bare :: proc(t: ^testing.T) {
	testing.expect(t, path_is_bare(""))
	testing.expect(t, path_is_bare("/usr/bin:/bin:/usr/sbin:/sbin"))
	testing.expect(t, path_is_bare("/usr/bin:/bin"))
	testing.expect(t, !path_is_bare("/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"))
	testing.expect(t, !path_is_bare("/usr/bin:/bin:/usr/sbin:/sbin:/Users/me/.local/bin"))
}

// The entries between the markers; noise before and after, and the
// shell's own session variables, left out.
@(test)
login_env_parse_markers :: proc(t: ^testing.T) {
	M :: LOGIN_ENV_MARK
	out := "Last login: noise\n" + M + "PATH=/opt/homebrew/bin:/usr/bin\x00MULTI=a\nb\x00PWD=/\x00SHLVL=1\x00_=/usr/bin/env\x00EMPTY=\x00" + M + "trailing noise\n"
	vars, ok := login_env_parse(out)
	testing.expect(t, ok)
	testing.expect_value(t, strings.join(vars, "|", context.temp_allocator), "PATH=/opt/homebrew/bin:/usr/bin|MULTI=a\nb|EMPTY=")
	// no end marker (cut off), no marker at all, no PATH: nothing
	_, ok = login_env_parse("noise " + M + "PATH=/usr/bin\x00")
	testing.expect(t, !ok)
	_, ok = login_env_parse("zsh:1: command not found: env\n")
	testing.expect(t, !ok)
	_, ok = login_env_parse(M + "HOME=/x\x00" + M)
	testing.expect(t, !ok)
}

// A real shell process: asked `-i -l -c`, its rc noise ignored.
@(test)
login_env_ask_fake_shell :: proc(t: ^testing.T) {
	d := le_dir("ask")
	defer os.remove_all(d)
	sh := le_fake_shell(d, "/le/brew/bin")
	vars, ok := login_env_ask(sh, 5 * time.Second)
	testing.expect(t, ok)
	path := ""
	rc := false
	for e in vars {
		if strings.has_prefix(e, "PATH=") do path = e[5:]
		if e == "LE_TEST_FROM_RC=yes" do rc = true
	}
	testing.expect(t, strings.has_prefix(path, "/le/brew/bin:"), path)
	testing.expect(t, rc, "the rc file's exports come along")
}

// A shell that hangs (a slow or waiting rc file) or fails: no answer, in time.
@(test)
login_env_ask_timeout_and_failure :: proc(t: ^testing.T) {
	d := le_dir("hang")
	defer os.remove_all(d)
	sh := le_fake_shell(d, "", "#!/bin/sh\necho noise\nexec sleep 30\n")
	start := time.tick_now()
	_, ok := login_env_ask(sh, 300 * time.Millisecond)
	testing.expect(t, !ok)
	testing.expect(t, time.tick_since(start) < 3 * time.Second, "stopped at the timeout")
	_, ok = login_env_ask(fmt.tprintf("%s/no-such-shell", d), time.Second)
	testing.expect(t, !ok)
	bad := le_fake_shell(d, "", "#!/bin/sh\nexit 1\n")
	_, ok = login_env_ask(bad, time.Second)
	testing.expect(t, !ok)
}

// The fallback: folders that exist and are not on PATH yet, in order.
@(test)
login_env_with_dirs_appends_existing :: proc(t: ^testing.T) {
	d := le_dir("dirs")
	defer os.remove_all(d)
	a := fmt.tprintf("%s/a", d)
	b := fmt.tprintf("%s/b", d)
	os.make_directory(a)
	os.make_directory(b)
	got := login_env_with_dirs("/usr/bin:/bin", {a, fmt.tprintf("%s/missing", d), "/usr/bin", b, a})
	testing.expect_value(t, got, fmt.tprintf("/usr/bin:/bin:%s:%s", a, b))
	testing.expect_value(t, login_env_with_dirs("", {a}), a)
	// the defaults: Homebrew and the per-user installers, under HOME
	dirs := login_env_dirs("/Users/x")
	for want in ([?]string{"/opt/homebrew/bin", "/usr/local/bin", "/Users/x/.local/bin", "/Users/x/.npm-global/bin", "/Users/x/.volta/bin", "/Users/x/.bun/bin"}) {
		found := false
		for x in dirs do if x == want do found = true
		testing.expectf(t, found, "default folder %s", want)
	}
}

// The whole fix on this process's environment (restored after): a bare
// PATH takes the shell's environment; a failing shell, the fallback
// folders; a PATH from a terminal is left alone.
@(test)
login_env_fix_applies :: proc(t: ^testing.T) {
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator), context.temp_allocator)
	defer os.set_env("PATH", old_path)
	defer os.unset_env("LE_TEST_FROM_RC")
	d := le_dir("fix")
	defer os.remove_all(d)
	fb := fmt.tprintf("%s/fallback", d)
	os.make_directory(fb)
	sh := le_fake_shell(d, "/le/brew/bin")

	os.set_env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
	testing.expect_value(t, login_env_fix(sh, {fb}, 5 * time.Second), Login_Env_Result.Shell)
	testing.expect(t, strings.has_prefix(os.get_env("PATH", context.temp_allocator), "/le/brew/bin:"))
	testing.expect_value(t, os.get_env("LE_TEST_FROM_RC", context.temp_allocator), "yes")

	os.set_env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
	testing.expect_value(t, login_env_fix(fmt.tprintf("%s/no-such-shell", d), {fb}, time.Second), Login_Env_Result.Fallback)
	testing.expect_value(t, os.get_env("PATH", context.temp_allocator), fmt.tprintf("/usr/bin:/bin:/usr/sbin:/sbin:%s", fb))

	os.set_env("PATH", "/opt/homebrew/bin:/usr/bin:/bin")
	testing.expect_value(t, login_env_fix(sh, {fb}, 5 * time.Second), Login_Env_Result.Kept)
	testing.expect_value(t, os.get_env("PATH", context.temp_allocator), "/opt/homebrew/bin:/usr/bin:/bin")
}

// The shell runs in a session of its own: no controlling terminal to stop
// it (a pi-desk started from a terminal with a bare PATH: `zsh -i` would
// open /dev/tty from a background group and stop on SIGTTIN).
@(test)
login_env_probe_new_session :: proc(t: ^testing.T) {
	d := le_dir("sid")
	defer os.remove_all(d)
	sh := le_fake_shell(d, "", fmt.tprintf(
		"#!/bin/sh\n" +
		"sid=$(/usr/bin/python3 -I -c 'import os; print(os.getsid(os.getppid()))')\n" +
		"printf '%%s' '%s'; printf 'PATH=/x\\0SID=%%s\\0PID=%%s\\0' \"$sid\" \"$$\"; printf '%%s' '%s'\n",
		LOGIN_ENV_MARK, LOGIN_ENV_MARK,
	))
	vars, ok := login_env_ask(sh, 5 * time.Second)
	testing.expect(t, ok)
	sid, pid := "", "-"
	for e in vars {
		if strings.has_prefix(e, "SID=") do sid = e[4:]
		if strings.has_prefix(e, "PID=") do pid = e[4:]
	}
	testing.expectf(t, sid == pid, "the shell leads its own session (sid %s, pid %s)", sid, pid)
}

// An rc file that starts something in the background (holding the output
// pipe): the answer comes when the shell exits, and that process is left alone.
@(test)
login_env_probe_background_job :: proc(t: ^testing.T) {
	d := le_dir("bg")
	defer os.remove_all(d)
	pidf := fmt.tprintf("%s/bg.pid", d)
	sh := le_fake_shell(d, "", fmt.tprintf(
		"#!/bin/sh\n" +
		"sleep 30 &\necho $! > '%s'\n" +
		"printf '%%s' '%s'; printf 'PATH=/le/bg/bin\\0'; printf '%%s' '%s'\n",
		pidf, LOGIN_ENV_MARK, LOGIN_ENV_MARK,
	))
	start := time.tick_now()
	vars, ok := login_env_ask(sh, 4 * time.Second)
	took := time.tick_since(start)
	data, _ := os.read_entire_file(pidf, context.temp_allocator)
	bg := strings.trim_space(string(data))
	time.sleep(300 * time.Millisecond) // a killed one is reaped by then (not a zombie)
	alive := bg != "" && posix_alive(bg)
	if bg != "" do kill_pid(bg) // only the process this test started
	testing.expect(t, ok)
	testing.expect(t, len(vars) == 1 && vars[0] == "PATH=/le/bg/bin")
	testing.expectf(t, took < time.Second, "answered at the shell's exit (%v)", took)
	testing.expect(t, alive, "the background process still runs")
}

// A shell that never answers is killed at the timeout (interactive shells
// ignore SIGTERM: no grace for it).
@(test)
login_env_probe_timeout_kills :: proc(t: ^testing.T) {
	d := le_dir("kill")
	defer os.remove_all(d)
	sh := le_fake_shell(d, "", "#!/bin/sh\ntrap '' TERM\necho noise\nwhile :; do sleep 1; done\n")
	start := time.tick_now()
	_, ok := login_env_ask(sh, 500 * time.Millisecond)
	testing.expect(t, !ok)
	testing.expectf(t, time.tick_since(start) < 1500 * time.Millisecond, "killed at the timeout (%v)", time.tick_since(start))
}

// pi-desk's own switches never come from the user's shell (PI_DESK_SCRIPT
// would turn on test mode).
@(test)
login_env_parse_skips_pi_desk :: proc(t: ^testing.T) {
	M :: LOGIN_ENV_MARK
	vars, ok := login_env_parse(M + "PATH=/a\x00PI_DESK_SCRIPT=x.txt\x00PI_DESK_CMD=cat\x00PI_KIT_NOTES_DIR=/n\x00" + M)
	testing.expect(t, ok)
	testing.expect_value(t, strings.join(vars, "|", context.temp_allocator), "PATH=/a|PI_KIT_NOTES_DIR=/n")
}

@(private = "file")
posix_alive :: proc(pid: string) -> bool {
	n := 0
	for c in pid do n = n * 10 + int(c - '0')
	return n > 0 && posix.kill(posix.pid_t(n), posix.Signal(0)) == .OK
}

@(private = "file")
kill_pid :: proc(pid: string) {
	n := 0
	for c in pid do n = n * 10 + int(c - '0')
	if n > 0 do posix.kill(posix.pid_t(n), .SIGKILL)
}
