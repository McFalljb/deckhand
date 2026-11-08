package main

// login_env.odin: a Dock launch takes the interactive login shell's
// environment. Fake shells are tiny /bin/sh scripts in a temp folder.

import "base:runtime"
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
	vars, ok := login_env_ask(sh, LE_ANSWER_TIMEOUT)
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
	testing.expect(t, time.tick_since(start) < LE_STOPPED_WITHIN, "stopped at the timeout")
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

// The whole fix on this process's environment (restored after): a GUI
// launch takes the shell's environment; a failing shell, the fallback
// folders; a terminal launch is left alone.
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
	testing.expect_value(t, login_env_fix(true, sh, {fb}, LE_ANSWER_TIMEOUT), Login_Env_Result.Shell)
	testing.expect(t, strings.has_prefix(os.get_env("PATH", context.temp_allocator), "/le/brew/bin:"))
	testing.expect_value(t, os.get_env("LE_TEST_FROM_RC", context.temp_allocator), "yes")

	os.unset_env("LE_TEST_FROM_RC")
	os.set_env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
	testing.expect_value(t, login_env_fix(true, fmt.tprintf("%s/no-such-shell", d), {fb}, time.Second), Login_Env_Result.Fallback)
	testing.expect_value(t, os.get_env("PATH", context.temp_allocator), fmt.tprintf("/usr/bin:/bin:/usr/sbin:/sbin:%s", fb))

	// a terminal launch: nothing asked, nothing changed (even with the shell's answer at hand)
	os.set_env("PATH", "/opt/homebrew/bin:/usr/bin:/bin")
	le_stub_calls = 0
	testing.expect_value(t, login_env_fix(false, sh, {fb}, LE_ANSWER_TIMEOUT, le_stub_probe), Login_Env_Result.Kept)
	testing.expect_value(t, le_stub_calls, 0)
	testing.expect_value(t, os.get_env("PATH", context.temp_allocator), "/opt/homebrew/bin:/usr/bin:/bin")
	_, found := os.lookup_env("LE_TEST_FROM_RC", context.temp_allocator)
	testing.expect(t, !found)
}

// What the stub probe answers (the shell's environment, parsed), and how often it was asked.
@(private = "file")
le_stub_answer: []string
@(private = "file")
le_stub_ok: bool
@(private = "file")
le_stub_calls: int
@(private = "file")
le_stub_env: []string

@(private = "file")
le_stub_probe :: proc(shell: string, timeout: time.Duration, env: []string) -> ([]string, bool) {
	le_stub_calls += 1
	le_stub_env = env
	return le_stub_answer, le_stub_ok
}

@(private = "file")
NIX_PATH_GUI :: "/Users/le/.nix-profile/bin:/run/current-system/sw/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

// Issue #2: a Dock launch whose PATH is not bare (Nix profile folders from
// launchd) still asks the shell. Its Homebrew and managed-pi folders and a
// marker variable come in; inherited values win; PATH is the shell's order,
// then the inherited folders it lacks, each once.
@(test)
login_env_gui_nix_path_merges :: proc(t: ^testing.T) {
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator), context.temp_allocator)
	defer os.set_env("PATH", old_path)
	defer os.unset_env("LE_MARKER_PROFILE")
	defer os.unset_env("LE_INHERITED")
	os.set_env("PATH", NIX_PATH_GUI)
	os.set_env("LE_INHERITED", "from-launchd")
	testing.expect(t, !path_is_bare(NIX_PATH_GUI))
	gui := login_env_gui_launch(1, NIX_PATH_GUI, "")
	testing.expect(t, gui, "the parent is launchd: a GUI launch, whatever PATH is")
	le_stub_answer = {
		"PATH=/opt/homebrew/bin:/Users/le/.pi/agent/bin:/Users/le/.nix-profile/bin:/run/current-system/sw/bin:/usr/bin:/bin:/usr/bin",
		"LE_MARKER_PROFILE=le-test-profile",
		"LE_INHERITED=from-zshrc",
	}
	le_stub_ok = true
	le_stub_calls = 0
	testing.expect_value(t, login_env_fix(gui, "/le/fake-shell", {}, time.Second, le_stub_probe), Login_Env_Result.Shell)
	testing.expect_value(t, le_stub_calls, 1)
	testing.expect_value(t, os.get_env("PATH", context.temp_allocator),
		"/opt/homebrew/bin:/Users/le/.pi/agent/bin:/Users/le/.nix-profile/bin:/run/current-system/sw/bin:/usr/bin:/bin:/nix/var/nix/profiles/default/bin:/usr/local/bin:/usr/sbin:/sbin")
	testing.expect_value(t, os.get_env("LE_MARKER_PROFILE", context.temp_allocator), "le-test-profile")
	testing.expect_value(t, os.get_env("LE_INHERITED", context.temp_allocator), "from-zshrc") // the rc file changed it on purpose
}

// Review round 1: the shell's value wins (as in a terminal: an rc file that
// exports a 1Password socket beats launchd's SSH agent); a value the shell
// left alone and an inherited-only variable are kept; the skip list never
// comes from the shell, even through a stub.
@(test)
login_env_shell_wins :: proc(t: ^testing.T) {
	inh := []string{"SSH_AUTH_SOCK=/launchd/agent", "LE_SAME=v", "LE_ONLY_INHERITED=i", "PWD=/inh", "PATH=/usr/bin:/bin"}
	sh := []string{"SSH_AUTH_SOCK=/1p/agent.sock", "LE_SAME=v", "PWD=/shell", "SHLVL=3", "DECKHAND_SCRIPT=x", "PATH=/opt/homebrew/bin:/usr/bin"}
	env, res := login_env_compose(inh, sh, true, {})
	testing.expect_value(t, res, Login_Env_Result.Shell)
	got := strings.join(env, "|", context.temp_allocator)
	testing.expect_value(t, got, "SSH_AUTH_SOCK=/1p/agent.sock|LE_SAME=v|LE_ONLY_INHERITED=i|PWD=/inh|PATH=/opt/homebrew/bin:/usr/bin:/bin")
}

// GUI or terminal: launchd as the parent, a bare PATH, or the switch.
@(test)
login_env_gui_detection :: proc(t: ^testing.T) {
	testing.expect(t, login_env_gui_launch(1, NIX_PATH_GUI, ""))
	testing.expect(t, login_env_gui_launch(4242, "/usr/bin:/bin:/usr/sbin:/sbin", ""), "a bare PATH, as before")
	testing.expect(t, !login_env_gui_launch(4242, NIX_PATH_GUI, ""), "a terminal (its shell the parent)")
	testing.expect(t, !login_env_gui_launch(4242, "/opt/homebrew/bin:/usr/bin", ""))
	testing.expect(t, login_env_gui_launch(4242, NIX_PATH_GUI, "1"))
	testing.expect(t, !login_env_gui_launch(1, "/usr/bin", "0"), "turned off")
	// review round 1: test mode (DECKHAND_SCRIPT) never asks the real shell unless told to
	testing.expect(t, !login_env_gui_launch(1, "/usr/bin:/bin", "", test_mode = true))
	testing.expect(t, !login_env_gui_launch(1, "/usr/bin:/bin", "0", test_mode = true))
	testing.expect(t, login_env_gui_launch(4242, NIX_PATH_GUI, "1", test_mode = true))
}

// The merge itself: the shell's values win, PATH entries once, empty ones dropped;
// no answer (or a bare PATH from the shell) is the fallback.
@(test)
login_env_compose_rules :: proc(t: ^testing.T) {
	d := le_dir("compose")
	defer os.remove_all(d)
	inh := []string{"HOME=/h", "PATH=/a::/usr/bin", "EMPTY="}
	env, res := login_env_compose(inh, {"PATH=/b:/a:/b", "HOME=/other", "EMPTY=x", "NEW=1"}, true, {d})
	testing.expect_value(t, res, Login_Env_Result.Shell)
	testing.expect_value(t, strings.join(env, "|", context.temp_allocator), "HOME=/other|EMPTY=x|NEW=1|PATH=/b:/a:/usr/bin")
	env, res = login_env_compose(inh, nil, false, {d})
	testing.expect_value(t, res, Login_Env_Result.Fallback)
	testing.expect_value(t, strings.join(env, "|", context.temp_allocator), fmt.tprintf("HOME=/h|EMPTY=|PATH=/a:/usr/bin:%s", d))
	env, res = login_env_compose(inh, {"PATH=/usr/bin:/bin", "NEW=1"}, true, {d})
	testing.expect_value(t, res, Login_Env_Result.Fallback)
	testing.expect_value(t, strings.join(env, "|", context.temp_allocator), fmt.tprintf("HOME=/h|EMPTY=|NEW=1|PATH=/usr/bin:/bin:/a:%s", d))
}

// A real (fake) shell through the whole fix: its session variables and
// DECKHAND_* switches never come in.
@(test)
login_env_fix_skip_list :: proc(t: ^testing.T) {
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator), context.temp_allocator)
	defer os.set_env("PATH", old_path)
	old_shlvl, had_shlvl := os.lookup_env("SHLVL", context.temp_allocator)
	defer if had_shlvl do os.set_env("SHLVL", old_shlvl)
	os.unset_env("SHLVL")
	defer os.unset_env("LE_SKIP_OK")
	d := le_dir("skip")
	defer os.remove_all(d)
	sh := le_fake_shell(d, "", fmt.tprintf(
		"#!/bin/sh\nprintf '%%s' '%s'; printf 'PATH=/le/skip/bin\\0SHLVL=9\\0PWD=/le\\0OLDPWD=/le\\0_=/x\\0DECKHAND_SCRIPT=evil.txt\\0LE_SKIP_OK=1\\0'; printf '%%s' '%s'\n",
		LOGIN_ENV_MARK, LOGIN_ENV_MARK,
	))
	os.set_env("PATH", NIX_PATH_GUI)
	testing.expect_value(t, login_env_fix(true, sh, {}, LE_ANSWER_TIMEOUT), Login_Env_Result.Shell)
	testing.expect_value(t, os.get_env("LE_SKIP_OK", context.temp_allocator), "1")
	for k in ([]string{"SHLVL", "DECKHAND_SCRIPT"}) {
		_, found := os.lookup_env(k, context.temp_allocator)
		testing.expectf(t, !found, "%s not imported", k)
	}
	testing.expect(t, os.get_env("PWD", context.temp_allocator) != "/le")
	testing.expect(t, strings.has_prefix(os.get_env("PATH", context.temp_allocator), "/le/skip/bin:"))
}

// A GUI launch whose shell hangs: killed at the timeout, the fallback folders.
@(test)
login_env_fix_timeout_fallback :: proc(t: ^testing.T) {
	old_path := strings.clone(os.get_env("PATH", context.temp_allocator), context.temp_allocator)
	defer os.set_env("PATH", old_path)
	d := le_dir("fixhang")
	defer os.remove_all(d)
	fb := fmt.tprintf("%s/fallback", d)
	os.make_directory(fb)
	sh := le_fake_shell(d, "", "#!/bin/sh\ntrap '' TERM\necho noise\nwhile :; do sleep 1; done\n")
	os.set_env("PATH", NIX_PATH_GUI)
	start := time.tick_now()
	testing.expect_value(t, login_env_fix(true, sh, {fb}, 400 * time.Millisecond), Login_Env_Result.Fallback)
	testing.expectf(t, time.tick_since(start) < LE_STOPPED_WITHIN, "stopped at the timeout (%v)", time.tick_since(start))
	testing.expect_value(t, os.get_env("PATH", context.temp_allocator), fmt.tprintf("%s:%s", NIX_PATH_GUI, fb))
}

// The usual folders include pi's managed install and Homebrew, and a moved
// agent directory's bin first.
@(test)
login_env_dirs_managed :: proc(t: ^testing.T) {
	old, had := os.lookup_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	defer le_restore("PI_CODING_AGENT_DIR", old, had)
	os.set_env("PI_CODING_AGENT_DIR", "/le/agent/")
	dirs := login_env_dirs("/Users/x")
	testing.expect_value(t, dirs[0], "/le/agent/bin")
	for want in ([?]string{"/opt/homebrew/bin", "/usr/local/bin", "/Users/x/.local/bin", "/Users/x/.pi/agent/bin"}) {
		found := false
		for x in dirs do if x == want do found = true
		testing.expectf(t, found, "default folder %s", want)
	}
}

// The tabs' commands, run by /bin/sh with a fake HOME and a PATH without
// them: pi's managed install runs (and says where it was found); neither: 127
// with what to do. Never a real pi or claude: fake scripts only.
@(private = "file")
le_run_cmd :: proc(cmd, name, home, agent_dir: string, cwd := "") -> (out: string, code: int) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "/usr/bin/env", "-i", fmt.tprintf("HOME=%s", home), "PATH=/usr/bin:/bin")
	if agent_dir != "" do append(&argv, fmt.tprintf("PI_CODING_AGENT_DIR=%s", agent_dir))
	append(&argv, "/bin/sh", "-c", cmd, name, "--le-arg")
	return le_capture(argv[:], cwd)
}

@(private = "file")
le_capture :: proc(argv: []string, cwd := "") -> (string, int) {
	r, w, perr := os.pipe()
	if perr != nil do return "", -1
	defer os.close(r)
	p, err := os.process_start({command = argv, working_dir = cwd, stdout = w, stderr = w})
	os.close(w)
	if err != nil do return "", -1
	data, _ := os.read_entire_file(r, context.temp_allocator)
	st, _ := os.process_wait(p)
	return string(data), st.exit_code
}

@(private = "file")
le_fake_bin :: proc(dir, name, tag: string) {
	os.make_directory_all(dir)
	f := fmt.tprintf("%s/%s", dir, name)
	_ = os.write_entire_file(f, transmute([]u8)fmt.tprintf("#!/bin/sh\necho \"FAKE %s $*\"\n", tag))
	_ = os.chmod(f, os.perm_number(0o755))
}

@(test)
login_env_managed_pi_discovery :: proc(t: ^testing.T) {
	d := le_dir("managed")
	defer os.remove_all(d)
	home := fmt.tprintf("%s/home", d)
	os.make_directory_all(home)
	// nowhere: 127, and the message says both places were looked at
	out, code := le_run_cmd(PI_TAB_CMD, "pi", home, "")
	testing.expect_value(t, code, 127)
	testing.expect(t, strings.contains(out, "pi was not found") && strings.contains(out, "~/.pi/agent/bin"), out)
	// ~/.pi/agent/bin/pi: runs, after saying where it is
	le_fake_bin(fmt.tprintf("%s/.pi/agent/bin", home), "pi", "MANAGED")
	out, code = le_run_cmd(PI_TAB_CMD, "pi", home, "")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, fmt.tprintf("pi is installed at %s/.pi/agent/bin/pi but is not on your login shell's PATH", home)), out)
	testing.expect(t, strings.contains(out, "FAKE MANAGED --le-arg"), out)
	// $PI_CODING_AGENT_DIR/bin/pi comes first
	le_fake_bin(fmt.tprintf("%s/agent/bin", d), "pi", "AGENTDIR")
	out, _ = le_run_cmd(PI_TAB_CMD, "pi", home, fmt.tprintf("%s/agent", d))
	testing.expect(t, strings.contains(out, "FAKE AGENTDIR --le-arg"), out)
	// review round 1: a relative PI_CODING_AGENT_DIR is never used (it would be the project's own rel/bin/pi)
	le_fake_bin(fmt.tprintf("%s/proj/rel/bin", d), "pi", "REPO")
	out, _ = le_run_cmd(PI_TAB_CMD, "pi", home, "rel", fmt.tprintf("%s/proj", d))
	testing.expect(t, !strings.contains(out, "FAKE REPO"), out)
	testing.expect(t, strings.contains(out, "FAKE MANAGED --le-arg"), out)
	// a literal ~ in PI_CODING_AGENT_DIR is the home folder, as pi reads it (expandTildePath)
	le_fake_bin(fmt.tprintf("%s/agentdir/bin", home), "pi", "TILDE")
	out, _ = le_run_cmd(PI_TAB_CMD, "pi", home, "~/agentdir")
	testing.expect(t, strings.contains(out, "FAKE TILDE --le-arg"), out)
	// on PATH: that one, no note
	le_fake_bin(fmt.tprintf("%s/path", d), "pi", "ONPATH")
	out, _ = le_capture({"/usr/bin/env", "-i", fmt.tprintf("HOME=%s", home), fmt.tprintf("PATH=%s/path:/usr/bin:/bin", d), "/bin/sh", "-c", PI_TAB_CMD, "pi", "x"})
	testing.expect_value(t, out, "FAKE ONPATH x\n")
	// Deckhand's own lookup (jobs, the reload probe) finds the same
	old_home := strings.clone(os.get_env("HOME", context.temp_allocator), context.temp_allocator)
	defer os.set_env("HOME", old_home)
	old_cad, had_cad := os.lookup_env("PI_CODING_AGENT_DIR", context.temp_allocator)
	defer le_restore("PI_CODING_AGENT_DIR", old_cad, had_cad)
	os.set_env("HOME", home)
	os.unset_env("PI_CODING_AGENT_DIR")
	testing.expect_value(t, pi_managed_path(), fmt.tprintf("%s/.pi/agent/bin/pi", home))
	os.set_env("PI_CODING_AGENT_DIR", fmt.tprintf("%s/agent", d))
	testing.expect_value(t, pi_managed_path(), fmt.tprintf("%s/agent/bin/pi", d))
	os.set_env("HOME", fmt.tprintf("%s/nohome", d))
	os.unset_env("PI_CODING_AGENT_DIR")
	testing.expect_value(t, pi_managed_path(), "")
}

@(test)
login_env_managed_claude_discovery :: proc(t: ^testing.T) {
	d := le_dir("claude")
	defer os.remove_all(d)
	home := fmt.tprintf("%s/home", d)
	os.make_directory_all(home)
	out, code := le_run_cmd(CLAUDE_TAB_CMD, "claude", home, "")
	testing.expect_value(t, code, 127)
	testing.expect(t, strings.contains(out, "Claude Code (claude) was not found"), out)
	// a relative HOME is never used for Claude's folders either
	le_fake_bin(fmt.tprintf("%s/proj/relhome/.local/bin", d), "claude", "REPO")
	out, code = le_run_cmd(CLAUDE_TAB_CMD, "claude", "relhome", "", fmt.tprintf("%s/proj", d))
	testing.expect_value(t, code, 127)
	testing.expect(t, !strings.contains(out, "FAKE REPO"), out)
	le_fake_bin(fmt.tprintf("%s/.claude/local", home), "claude", "OLDLOCAL")
	out, code = le_run_cmd(CLAUDE_TAB_CMD, "claude", home, "")
	testing.expect_value(t, code, 0)
	testing.expect(t, strings.contains(out, "FAKE OLDLOCAL --le-arg"), out)
	le_fake_bin(fmt.tprintf("%s/.local/bin", home), "claude", "NATIVE")
	out, _ = le_run_cmd(CLAUDE_TAB_CMD, "claude", home, "")
	testing.expect(t, strings.contains(out, fmt.tprintf("Claude Code is installed at %s/.local/bin/claude", home)), out)
	testing.expect(t, strings.contains(out, "FAKE NATIVE --le-arg"), out)
}

// "Refresh shell environment": refused for a terminal launch; for a GUI
// launch it asks the (fake) shell again with the LAUNCH environment, and new
// tabs' environment (child_env) has the new answer while this process's
// own is unchanged.
@(test)
login_env_refresh_action :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	old_shell := strings.clone(os.get_env("SHELL", context.temp_allocator), context.temp_allocator)
	defer os.set_env("SHELL", old_shell)
	saved := login_env
	defer {
		if login_env.children != nil && raw_data(login_env.children) != raw_data(saved.children) {
			for e in login_env.children do delete(e, runtime.heap_allocator())
			delete(login_env.children, runtime.heap_allocator())
		}
		login_env = saved
	}
	d := le_dir("refresh")
	defer os.remove_all(d)
	count := fmt.tprintf("%s/count", d)
	// each interactive start answers LE_REFRESH_N=<how many times it was asked>; LE_LAUNCH_SEEN: what it inherited
	sh := le_fake_shell(d, "", fmt.tprintf(
		"#!/bin/sh\nn=$(($(cat '%s' 2>/dev/null || echo 0) + 1)); echo $n > '%s'\n" +
		"printf '%%s' '%s'; printf 'PATH=/le/refresh/bin:/usr/bin\\0LE_REFRESH_N=%%s\\0LE_LAUNCH_SEEN=%%s\\0' \"$n\" \"${{LE_LAUNCH_ONLY:-none}}\"; printf '%%s' '%s'\n",
		count, count, LOGIN_ENV_MARK, LOGIN_ENV_MARK,
	))
	os.set_env("SHELL", sh)

	login_env = {}
	r := run_command(Refresh_Shell_Env{}, {kind = .UI})
	testing.expect(t, !r.ok && strings.contains(r.error, "started from a terminal"), r.error)

	login_env = {gui = true, launch = {"HOME=/le/home", "PATH=/usr/bin:/bin", "LE_LAUNCH_ONLY=yes"}}
	// a fake shell's start under load took longer than the 4 s a real one gets (no slower when it passes)
	old_timeout := login_env_refresh_timeout
	login_env_refresh_timeout = 20 * time.Second
	defer login_env_refresh_timeout = old_timeout
	r = run_command(Refresh_Shell_Env{}, {kind = .UI})
	testing.expect(t, r.ok && r.pending)
	r2 := run_command(Refresh_Shell_Env{}, {kind = .UI})
	testing.expect(t, !r2.ok, "one at a time")
	deadline := time.tick_now()
	for login_env.running && time.tick_since(deadline) < 25 * time.Second {
		inbox_drain()
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, !login_env.running, "the worker answered")
	env := strings.join(child_env(), "|", context.temp_allocator)
	testing.expect(t, strings.contains(env, "|LE_REFRESH_N=1|"), env)
	testing.expectf(t, strings.contains(env, "LE_LAUNCH_SEEN=yes"), "asked with the launch environment: %s", env)
	testing.expect(t, strings.contains(env, "PATH=/le/refresh/bin:/usr/bin:/bin"), env)
	testing.expect(t, strings.contains(env, "HOME=/le/home"), env)
	testing.expect(t, strings.contains(env, "TERM_PROGRAM=Deckhand"), env)
	_, found := os.lookup_env("LE_REFRESH_N", context.temp_allocator)
	testing.expect(t, !found, "this process's environment is not changed")
}

// The shell runs in a session of its own: no controlling terminal to stop
// it (a Deckhand started from a terminal with a bare PATH: `zsh -i` would
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
	vars, ok := login_env_ask(sh, LE_ANSWER_TIMEOUT)
	testing.expect(t, ok)
	sid, pid := "", "-"
	for e in vars {
		if strings.has_prefix(e, "SID=") do sid = e[4:]
		if strings.has_prefix(e, "PID=") do pid = e[4:]
	}
	testing.expectf(t, sid == pid, "the shell leads its own session (sid %s, pid %s)", sid, pid)
}

// Time limits for the tests that run a real /bin/sh: generous, because a busy machine (other
// builds, tests/unit.py's other processes) can take seconds to start and end a shell. A shell
// that answers is waited for up to LE_ANSWER_TIMEOUT (no slower when it is quick); a hanging or
// backgrounded one must be done within LE_STOPPED_WITHIN, still far below the 30 s, the endless
// loop or the 10 s timeout the tests tell it apart from.
LE_ANSWER_TIMEOUT :: 15 * time.Second
LE_STOPPED_WITHIN :: 5 * time.Second

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
	vars, ok := login_env_ask(sh, 10 * time.Second)
	took := time.tick_since(start)
	data, _ := os.read_entire_file(pidf, context.temp_allocator)
	bg := strings.trim_space(string(data))
	time.sleep(300 * time.Millisecond) // a killed one is reaped by then (not a zombie)
	alive := bg != "" && posix_alive(bg)
	if bg != "" do kill_pid(bg) // only the process this test started
	testing.expect(t, ok)
	testing.expect(t, len(vars) == 1 && vars[0] == "PATH=/le/bg/bin")
	testing.expectf(t, took < LE_STOPPED_WITHIN, "answered at the shell's exit (%v)", took)
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
	testing.expectf(t, time.tick_since(start) < LE_STOPPED_WITHIN, "killed at the timeout (%v)", time.tick_since(start))
}

// Deckhand's own switches never come from the user's shell (DECKHAND_SCRIPT
// would turn on test mode).
@(test)
login_env_parse_skips_deckhand :: proc(t: ^testing.T) {
	M :: LOGIN_ENV_MARK
	vars, ok := login_env_parse(M + "PATH=/a\x00DECKHAND_SCRIPT=x.txt\x00DECKHAND_CMD=cat\x00PI_KIT_NOTES_DIR=/n\x00" + M)
	testing.expect(t, ok)
	testing.expect_value(t, strings.join(vars, "|", context.temp_allocator), "PATH=/a|PI_KIT_NOTES_DIR=/n")
}

// Review round 1: quitting while a refresh waits on a stuck rc file kills the
// probe's whole session group at once (not only at the worker's timeout).
@(test)
login_env_quit_kills_probe :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	saved := login_env
	defer login_env = saved
	d := le_dir("quit")
	defer os.remove_all(d)
	sh := le_fake_shell(d, "", "#!/bin/sh\ntrap '' TERM\necho noise\nwhile :; do sleep 1; done\n")
	old_shell := strings.clone(os.get_env("SHELL", context.temp_allocator), context.temp_allocator)
	defer os.set_env("SHELL", old_shell)
	os.set_env("SHELL", sh)
	login_env = {gui = true, launch = {"HOME=/le/home", "PATH=/usr/bin:/bin"}}
	testing.expect(t, login_env_refresh_start(0, timeout = 60 * time.Second))
	pid: i32
	start := time.tick_now()
	for pid == 0 && time.tick_since(start) < 5 * time.Second {
		pid = login_env_probe_pid()
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, pid > 0, "the probe is running")
	login_env_kill_probe() // what cleanup (quit) calls
	gone := false
	for time.tick_since(start) < 5 * time.Second {
		if posix.killpg(posix.pid_t(pid), posix.Signal(0)) != .OK {
			gone = true
			break
		}
		time.sleep(20 * time.Millisecond)
	}
	testing.expect(t, gone, "the probe's group is gone")
	testing.expect(t, time.tick_since(start) < 5 * time.Second)
	for login_env.running && time.tick_since(start) < 10 * time.Second {
		inbox_drain()
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, !login_env.running, "the worker answered (no environment)")
	testing.expect(t, login_env.children == nil)
}

@(private = "file")
le_restore :: proc(k, v: string, had: bool) {
	if had do os.set_env(k, v)
	else do os.unset_env(k)
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

// ---- Claude Code's session markers (Deckhand started from inside a Claude Code session) ----

// What a running claude sets in its children (code.claude.com/docs/en/env-vars), as seen
// when Deckhand was `open`ed from a shell inside a Claude Code session.
@(private = "file")
LE_MARKERS :: [?]string{
	"CLAUDECODE=1",
	"CLAUDE_CODE_CHILD_SESSION=1",
	"CLAUDE_CODE_ENTRYPOINT=cli",
	"CLAUDE_CODE_EXECPATH=/le/parent/claude",
	"CLAUDE_CODE_MESSAGING_SOCKET=/le/sock",
	"CLAUDE_CODE_MESSAGING_TOKEN=le-token",
	"CLAUDE_CODE_SESSION_ATTENDED=1",
	"CLAUDE_CODE_SESSION_ID=0c1a0de0-1111-4222-8333-444455556666",
	"CLAUDE_PID=4242",
	"CLAUDE_CODE_SSE_PORT=12345",
	"CLAUDE_CODE_BRIDGE_SESSION_ID=session_le",
	"CLAUDE_JOB_DIR=/le/jobs/1",
}

@(private = "file")
le_env_has :: proc(env: []string, k: string) -> bool {
	_, found := env_lookup(env, k)
	return found
}

// Session markers are recognized by name; a user's own Claude settings are not markers
// (CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS is a setting, not CLAUDE_CODE_SESSION_*).
@(test)
login_env_claude_marker_names :: proc(t: ^testing.T) {
	for e in LE_MARKERS {
		k, _, _ := strings.partition(e, "=")
		testing.expectf(t, claude_session_marker(k), "%s is a session marker", k)
	}
	for k in ([]string{"CLAUDE_CONFIG_DIR", "CLAUDE_EFFORT", "ANTHROPIC_API_KEY", "CLAUDE_CODE_SESSIONEND_HOOKS_TIMEOUT_MS", "CLAUDE_CODE_USE_BEDROCK", "DECKHAND_CLAUDE_TOKEN", "CLAUDE"}) {
		testing.expectf(t, !claude_session_marker(k), "%s is not a session marker", k)
	}
	testing.expect(t, claude_config_var("CLAUDE_CONFIG_DIR") && claude_config_var("CLAUDE_EFFORT") && claude_config_var("CLAUDE_CODE_AUTO_COMPACT_WINDOW"))
	testing.expect(t, !claude_config_var("CLAUDECODE") && !claude_config_var("DECKHAND_CLAUDE_CMD") && !claude_config_var("HOME"))
	// pi and Atlas read ANTHROPIC_* too: never taken for the parent session's
	testing.expect(t, !claude_config_var("ANTHROPIC_DEFAULT_HAIKU_MODEL") && !claude_config_var("ANTHROPIC_API_KEY"))
	// from a Claude session: a marker only claude itself sets (CLAUDECODE alone: an IDE's terminal)
	testing.expect(t, login_env_from_claude({"CLAUDE_CODE_CHILD_SESSION=1"}))
	testing.expect(t, login_env_from_claude({"CLAUDE_CODE_SESSION_ID=x"}))
	testing.expect(t, login_env_from_claude({"CLAUDE_PID=1"}))
	testing.expect(t, !login_env_from_claude({"CLAUDECODE=1", "CLAUDE_CODE_SSE_PORT=1", "CLAUDE_CONFIG_DIR=/x"}))
}

// The merge never passes a marker on, whether inherited or printed by the shell.
@(test)
login_env_compose_drops_markers :: proc(t: ^testing.T) {
	inh := make([dynamic]string, context.temp_allocator)
	append(&inh, "HOME=/h", "PATH=/usr/bin")
	for e in LE_MARKERS do append(&inh, e)
	sh := []string{"PATH=/opt/homebrew/bin:/usr/bin", "CLAUDECODE=1", "CLAUDE_CODE_SESSION_ID=from-rc", "LE_RC=1"}
	for ok in ([]bool{true, false}) {
		env, _ := login_env_compose(inh[:], sh, ok, {})
		for e in env {
			k, _, _ := strings.partition(e, "=")
			testing.expectf(t, !claude_session_marker(k), "%s passed on (shell answered: %v)", k, ok)
		}
		testing.expect(t, le_env_has(env, "HOME"))
	}
}

// A terminal launch (nothing asked): the markers leave this process's environment at
// startup; the user's other Claude settings stay (there is no shell answer to tell).
@(test)
login_env_fix_strips_markers_terminal :: proc(t: ^testing.T) {
	saved, _ := os.environ(context.temp_allocator)
	defer le_env_reset(saved)
	for e in LE_MARKERS {
		k, _, v := strings.partition(e, "=")
		os.set_env(k, v)
	}
	os.set_env("CLAUDE_CONFIG_DIR", "/le/parent-config")
	le_stub_calls = 0
	testing.expect_value(t, login_env_fix(false, "/le/fake-shell", {}, time.Second, le_stub_probe), Login_Env_Result.Kept)
	testing.expect_value(t, le_stub_calls, 0)
	for e in LE_MARKERS {
		k, _, _ := strings.partition(e, "=")
		_, found := os.lookup_env(k, context.temp_allocator)
		testing.expectf(t, !found, "%s left in the environment", k)
	}
	testing.expect_value(t, os.get_env("CLAUDE_CONFIG_DIR", context.temp_allocator), "/le/parent-config")
}

// A launch from inside a Claude session asks the shell (as a GUI launch does), with the
// markers and the parent's Claude settings left out of what the shell inherits: its own
// values win, and a Claude setting it does not set (the parent's CLAUDE_CONFIG_DIR,
// CLAUDE_EFFORT) is gone. Without markers, an inherited CLAUDE_CONFIG_DIR stays, as before.
@(test)
login_env_fix_from_claude_session :: proc(t: ^testing.T) {
	saved, _ := os.environ(context.temp_allocator)
	defer le_env_reset(saved)
	testing.expect(t, login_env_gui_launch(4242, NIX_PATH_GUI, "", from_claude = true), "from a Claude session: the shell is asked")
	testing.expect(t, !login_env_gui_launch(4242, NIX_PATH_GUI, "0", from_claude = true), "turned off")
	testing.expect(t, !login_env_gui_launch(4242, NIX_PATH_GUI, "", test_mode = true, from_claude = true), "test mode never asks the real shell")
	os.set_env("PATH", NIX_PATH_GUI)
	for e in LE_MARKERS {
		k, _, v := strings.partition(e, "=")
		os.set_env(k, v)
	}
	os.set_env("CLAUDE_CONFIG_DIR", "/le/parent-config")
	os.set_env("CLAUDE_EFFORT", "max")
	os.set_env("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "100000")
	os.set_env("ANTHROPIC_DEFAULT_HAIKU_MODEL", "parent-haiku")
	os.set_env("ANTHROPIC_BASE_URL", "https://le-inherited")
	os.set_env("LE_KEPT", "inherited")
	le_stub_answer = {"PATH=/opt/homebrew/bin:/usr/bin", "ANTHROPIC_DEFAULT_HAIKU_MODEL=rc-haiku", "LE_KEPT=inherited"}
	le_stub_ok = true
	le_stub_calls = 0
	testing.expect_value(t, login_env_fix(true, "/le/fake-shell", {}, time.Second, le_stub_probe), Login_Env_Result.Shell)
	testing.expect_value(t, le_stub_calls, 1)
	// what the shell was started with: no marker, none of the parent's Claude settings
	testing.expect(t, le_stub_env != nil, "the shell gets the cleaned environment")
	for e in le_stub_env {
		k, _, _ := strings.partition(e, "=")
		testing.expectf(t, !claude_session_marker(k) && !claude_config_var(k), "the shell inherited %s", k)
	}
	for k in ([]string{"CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "CLAUDE_CODE_SESSION_ID", "CLAUDE_PID", "CLAUDE_CONFIG_DIR", "CLAUDE_EFFORT", "CLAUDE_CODE_AUTO_COMPACT_WINDOW"}) {
		_, found := os.lookup_env(k, context.temp_allocator)
		testing.expectf(t, !found, "%s left in the environment", k)
	}
	testing.expect_value(t, os.get_env("ANTHROPIC_DEFAULT_HAIKU_MODEL", context.temp_allocator), "rc-haiku")
	testing.expect_value(t, os.get_env("ANTHROPIC_BASE_URL", context.temp_allocator), "https://le-inherited") // ANTHROPIC_* stay (pi's too)
	testing.expect_value(t, os.get_env("LE_KEPT", context.temp_allocator), "inherited")
	// the shell gives no answer (fails, times out): only the markers go; the inherited settings stay
	le_env_reset(saved)
	os.set_env("PATH", NIX_PATH_GUI)
	os.set_env("CLAUDE_CODE_CHILD_SESSION", "1")
	os.set_env("CLAUDE_PID", "4242")
	os.set_env("CLAUDE_CONFIG_DIR", "/le/parent-config")
	os.set_env("CLAUDE_EFFORT", "max")
	le_stub_ok = false
	testing.expect_value(t, login_env_fix(true, "/le/fake-shell", {}, time.Second, le_stub_probe), Login_Env_Result.Fallback)
	testing.expect_value(t, os.get_env("CLAUDE_CONFIG_DIR", context.temp_allocator), "/le/parent-config")
	testing.expect_value(t, os.get_env("CLAUDE_EFFORT", context.temp_allocator), "max")
	for k in ([]string{"CLAUDE_CODE_CHILD_SESSION", "CLAUDE_PID"}) {
		_, found := os.lookup_env(k, context.temp_allocator)
		testing.expectf(t, !found, "%s left in the environment", k)
	}
	le_stub_ok = true
	// the login shell's own CLAUDE_CONFIG_DIR wins
	le_env_reset(saved)
	os.set_env("PATH", NIX_PATH_GUI)
	os.set_env("CLAUDE_CODE_CHILD_SESSION", "1")
	os.set_env("CLAUDE_CONFIG_DIR", "/le/parent-config")
	le_stub_answer = {"PATH=/opt/homebrew/bin:/usr/bin", "CLAUDE_CONFIG_DIR=/le/rc-config"}
	testing.expect_value(t, login_env_fix(true, "/le/fake-shell", {}, time.Second, le_stub_probe), Login_Env_Result.Shell)
	testing.expect_value(t, os.get_env("CLAUDE_CONFIG_DIR", context.temp_allocator), "/le/rc-config")
	// no Claude session: an inherited CLAUDE_CONFIG_DIR the shell does not set is the user's, kept
	le_env_reset(saved)
	os.set_env("PATH", NIX_PATH_GUI)
	os.unset_env("CLAUDE_CODE_CHILD_SESSION")
	os.unset_env("CLAUDE_CODE_SESSION_ID")
	os.unset_env("CLAUDE_PID")
	os.set_env("CLAUDE_CONFIG_DIR", "/le/launchd-config")
	le_stub_answer = {"PATH=/opt/homebrew/bin:/usr/bin"}
	testing.expect_value(t, login_env_fix(true, "/le/fake-shell", {}, time.Second, le_stub_probe), Login_Env_Result.Shell)
	testing.expect_value(t, os.get_env("CLAUDE_CONFIG_DIR", context.temp_allocator), "/le/launchd-config")
}

// Every child's environment (child_env: pi, Claude, shells; the refreshed one too) is
// without the markers, whatever the base it starts from holds.
@(test)
login_env_child_env_no_markers :: proc(t: ^testing.T) {
	saved := login_env.children
	defer login_env.children = saved
	base := make([]string, len(LE_MARKERS) + 2, context.temp_allocator)
	for e, i in LE_MARKERS do base[i] = e
	base[len(LE_MARKERS)] = "PATH=/usr/bin"
	base[len(LE_MARKERS) + 1] = "CLAUDE_CONFIG_DIR=/le/c"
	login_env.children = base
	env := child_env({"DECKHAND_CLAUDE_TAB=1"})
	for e in env {
		k, _, _ := strings.partition(e, "=")
		testing.expectf(t, !claude_session_marker(k), "%s reached a child", k)
	}
	testing.expect(t, le_env_has(env, "PATH") && le_env_has(env, "CLAUDE_CONFIG_DIR") && le_env_has(env, "DECKHAND_CLAUDE_TAB"))
}

// This process's environment back to `saved` (a test changed it).
@(private = "file")
le_env_reset :: proc(saved: []string) {
	now, _ := os.environ(context.temp_allocator)
	for e in now {
		k, _, _ := strings.partition(e, "=")
		if _, had := env_lookup(saved, k); !had do os.unset_env(k)
	}
	for e in saved {
		k, _, v := strings.partition(e, "=")
		os.set_env(k, v)
	}
}

// "Refresh shell environment" after a launch from inside a Claude session: the same rules as the
// startup (login_env_shell_merge): asked without the parent's Claude settings; its answer merged;
// no answer, the launch environment as it was (markers already out).
@(test)
login_env_refresh_from_claude :: proc(t: ^testing.T) {
	launch := []string{"PATH=/usr/bin", "CLAUDE_CONFIG_DIR=/le/parent-config", "CLAUDE_EFFORT=max", "ANTHROPIC_BASE_URL=https://le", "LE_X=1"}
	le_stub_answer = {"PATH=/opt/homebrew/bin:/usr/bin", "LE_RC=1"}
	le_stub_ok = true
	env, _, ok := login_env_shell_merge(launch, true, "/le/fake-shell", time.Second, le_stub_probe, {})
	testing.expect(t, ok)
	for e in le_stub_env do testing.expectf(t, !strings.has_prefix(e, "CLAUDE_"), "the shell inherited %s", e)
	testing.expect(t, !le_env_has(env, "CLAUDE_CONFIG_DIR") && !le_env_has(env, "CLAUDE_EFFORT"))
	testing.expect(t, le_env_has(env, "ANTHROPIC_BASE_URL") && le_env_has(env, "LE_X") && le_env_has(env, "LE_RC"))
	le_stub_ok = false
	env, _, ok = login_env_shell_merge(launch, true, "/le/fake-shell", time.Second, le_stub_probe, {})
	testing.expect(t, !ok)
	testing.expect(t, le_env_has(env, "CLAUDE_CONFIG_DIR") && le_env_has(env, "CLAUDE_EFFORT"), "no answer: kept")
	// not from a Claude session: asked with everything, as before
	le_stub_ok = true
	env, _, ok = login_env_shell_merge(launch, false, "/le/fake-shell", time.Second, le_stub_probe, {})
	testing.expect(t, ok && le_env_has(env, "CLAUDE_CONFIG_DIR"))
}
