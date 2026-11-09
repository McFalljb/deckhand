#+build darwin
package core

// The holder's install (holder_install.odin), its direct spawn, and one real launchd launch
// with the test prefix (launchd_darwin.odin), which boots out every job it made and kills the
// holder it started. Nothing is left in launchd; ~/Library/LaunchAgents is never written (the
// plist lives in a temp dir and goes at once).

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

TEST_LABEL_PREFIX :: "dev.deckhand.test."

@(private = "file")
lt_dir :: proc(name: string) -> string {
	d := fmt.tprintf("%s/lt-%s-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), name, time.now()._nsec % 1_000_000_000)
	os.make_directory_all(d)
	return d
}

// A tiny C program at out (cc), signed ad hoc with identifier id ("" = left as the linker signed it).
@(private = "file")
lt_cc :: proc(t: ^testing.T, code, out, id: string) -> bool {
	src := fmt.tprintf("%s.c", out)
	_ = os.write_entire_file(src, transmute([]byte)code)
	if _, st := run_group({"/usr/bin/cc", "-o", out, src}, 60 * time.Second, merge_stderr = true); st != .Ok {
		testing.expect(t, false, "cc")
		return false
	}
	if id != "" {
		o, st := run_group({"/usr/bin/codesign", "-f", "-s", "-", "-i", id, out}, 30 * time.Second, merge_stderr = true)
		if !testing.expectf(t, st == .Ok, "codesign: %s", o) do return false
	}
	return true
}

@(private = "file")
LT_MAIN :: "int main(void) { return 0; }\n"

@(test)
holder_install_copies :: proc(t: ^testing.T) {
	d := lt_dir("inst")
	defer os.remove_all(d)
	bin := fmt.tprintf("%s/deckhand-core", d)
	if !lt_cc(t, LT_MAIN, bin, HOLDER_ID) do return
	_, xst := run_group({"/usr/bin/xattr", "-w", QUARANTINE_XATTR, "0081;00000000;Test;", bin}, 10 * time.Second)
	testing.expect(t, xst == .Ok && holder_quarantined(bin), "the source is quarantined")
	data := fmt.tprintf("%s/data", d)
	path, ok, why := holder_install(bin, data)
	if !testing.expectf(t, ok, "install: %s", why) do return
	defer delete(path)
	testing.expect(t, strings.has_prefix(path, fmt.tprintf("%s/core/%d-", data, HOLDER_REV)), "versioned dir")
	testing.expect(t, strings.has_suffix(path, "/deckhand-core"))
	testing.expect(t, !holder_quarantined(path), "the copy has no quarantine")
	testing.expect_value(t, holder_verify(path), "")
	st: posix.stat_t
	posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st)
	testing.expect_value(t, st.st_mode & (posix.S_IRWXU | posix.S_IRWXG | posix.S_IRWXO), posix.mode_t{.IRUSR, .IWUSR, .IXUSR, .IRGRP, .IXGRP, .IROTH, .IXOTH})
	ino := st.st_ino
	// identical: reused, not rewritten (a running holder's binary is never replaced)
	again, ok2, _ := holder_install(bin, data)
	defer delete(again)
	testing.expect(t, ok2)
	testing.expect_value(t, again, path)
	posix.stat(strings.clone_to_cstring(again, context.temp_allocator), &st)
	testing.expect_value(t, st.st_ino, ino)
	// a rebuild (another sha) goes beside it
	other := fmt.tprintf("%s/deckhand-core2", d)
	if !lt_cc(t, "int main(void) { return 1; }\n", other, HOLDER_ID) do return
	p3, ok3, _ := holder_install(other, data)
	defer delete(p3)
	testing.expect(t, ok3 && p3 != path, "a different binary, a different dir")
	// a development build is installed too: the next rebuild must not change a running holder's
	// file (only test mode runs the binary in place)
	repo := fmt.tprintf("%s/repo", d)
	helpers := fmt.tprintf("%s/build/Deckhand.app/Contents/Helpers", repo)
	os.make_directory_all(helpers)
	_ = os.write_entire_file(fmt.tprintf("%s/build.sh", repo), transmute([]byte)string("#!/bin/sh\n"))
	dev := fmt.tprintf("%s/deckhand-core", helpers)
	if !lt_cc(t, "int main(void) { return 2; }\n", dev, HOLDER_ID) do return
	p4, ok4, why4 := holder_install(dev, data)
	defer delete(p4)
	testing.expectf(t, ok4 && p4 != dev && strings.has_prefix(p4, fmt.tprintf("%s/core/", data)), "a dev build is installed: %q %s", p4, why4)
}

@(test)
holder_install_refuses :: proc(t: ^testing.T) {
	d := lt_dir("tamper")
	defer os.remove_all(d)
	bin := fmt.tprintf("%s/deckhand-core", d)
	if !lt_cc(t, LT_MAIN, bin, HOLDER_ID) do return
	// tampered after signing: one byte of the code changed
	b, _ := os.read_entire_file(bin, context.temp_allocator)
	i := len(b) / 4
	for i < len(b) && b[i] == 0 do i += 1
	b[i] ~= 0xff
	tampered := fmt.tprintf("%s/tampered", d)
	_ = os.write_entire_file(tampered, b)
	data := fmt.tprintf("%s/data", d)
	path, ok, why := holder_install(tampered, data)
	testing.expectf(t, !ok && path == "", "tampered: refused (%s)", why)
	testing.expectf(t, strings.contains(why, "signature"), "why: %q", why)
	// signed, but not as the holder
	wrong := fmt.tprintf("%s/wrong-id", d)
	if !lt_cc(t, LT_MAIN, wrong, "dev.example.other") do return
	_, ok2, why2 := holder_install(wrong, data)
	testing.expectf(t, !ok2, "another identifier: refused (%s)", why2)
	// nothing installed, no temp file left
	entries, _ := os.read_all_directory_by_path(fmt.tprintf("%s/core", data), context.temp_allocator)
	for e in entries {
		inner, _ := os.read_all_directory_by_path(fmt.tprintf("%s/core/%s", data, e.name), context.temp_allocator)
		testing.expectf(t, len(inner) == 0, "left in %s: %d files", e.name, len(inner))
	}
	_, ok3, _ := holder_install(fmt.tprintf("%s/missing", d), data)
	testing.expect(t, !ok3, "a missing binary")
}

// A tiny Deckhand Core.app at dir: a C main executable and one data file in Resources, signed ad
// hoc as a bundle with identifier id (its Info.plist's). The main executable's path.
@(private = "file")
lt_core_app :: proc(t: ^testing.T, dir, id: string, ret := 0) -> string {
	app := fmt.tprintf("%s/%s", dir, CORE_APP)
	os.make_directory_all(fmt.tprintf("%s/Contents/MacOS", app))
	os.make_directory_all(fmt.tprintf("%s/Contents/Resources/integrations", app))
	_ = os.write_entire_file(fmt.tprintf("%s/Contents/Info.plist", app), transmute([]byte)fmt.tprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>deckhand-core</string><key>CFBundleIdentifier</key><string>%s</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>9.8.7</string></dict></plist>
`, id))
	_ = os.write_entire_file(fmt.tprintf("%s/Contents/Resources/integrations/data.txt", app), transmute([]byte)string("integration\n"))
	exe := fmt.tprintf("%s/Contents/MacOS/deckhand-core", app)
	if !lt_cc(t, fmt.tprintf("int main(void) {{ return %d; }}\n", ret), exe, "") do return ""
	os.remove(fmt.tprintf("%s.c", exe)) // a stray file in MacOS would not be sealed
	o, st := run_group({"/usr/bin/codesign", "-f", "-s", "-", app}, 30 * time.Second, merge_stderr = true)
	if !testing.expectf(t, st == .Ok, "codesign %s: %s", app, o) do return ""
	return exe
}

// Deckhand Core.app is installed whole (§10.3 M4-A): copied, checked (--deep: its resources too),
// then unquarantined, under core/<rev>-<sha12>/; the holder runs from the copy.
@(test)
holder_install_core_app :: proc(t: ^testing.T) {
	d := lt_dir("app")
	defer os.remove_all(d)
	src := fmt.tprintf("%s/src", d)
	bin := lt_core_app(t, src, HOLDER_ID)
	if bin == "" do return
	testing.expect_value(t, holder_bundle_of(bin), fmt.tprintf("%s/%s", src, CORE_APP))
	testing.expect_value(t, holder_bundle_of(fmt.tprintf("%s/deckhand-core", d)), "")
	res := fmt.tprintf("%s/%s/Contents/Resources/integrations/data.txt", src, CORE_APP)
	for p in ([]string{bin, res}) {
		_, xst := run_group({"/usr/bin/xattr", "-w", QUARANTINE_XATTR, "0081;00000000;Test;", p}, 10 * time.Second)
		testing.expect(t, xst == .Ok && holder_quarantined(p), "the source is quarantined")
	}
	data := fmt.tprintf("%s/data", d)
	path, ok, why := holder_install(bin, data)
	if !testing.expectf(t, ok, "install: %s", why) do return
	defer delete(path)
	testing.expectf(t, strings.has_prefix(path, fmt.tprintf("%s/core/%d-", data, HOLDER_REV)) && strings.has_suffix(path, fmt.tprintf("/%s/Contents/MacOS/deckhand-core", CORE_APP)), "the copy's main executable: %s", path)
	copy_app := holder_bundle_of(path)
	testing.expect_value(t, holder_verify(copy_app), "")
	testing.expect(t, !holder_quarantined(path), "the copy's binary has no quarantine")
	testing.expect(t, !holder_quarantined(fmt.tprintf("%s/Contents/Resources/integrations/data.txt", copy_app)), "nor its resources")
	st: posix.stat_t
	posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st)
	ino := st.st_ino
	again, ok2, _ := holder_install(bin, data)
	defer delete(again)
	testing.expect(t, ok2 && again == path, "identical: reused")
	posix.stat(strings.clone_to_cstring(again, context.temp_allocator), &st)
	testing.expect_value(t, st.st_ino, ino)

	// a resource changed after signing: the copy fails --deep, nothing is installed
	bad := fmt.tprintf("%s/bad", d)
	bad_bin := lt_core_app(t, bad, HOLDER_ID, 1)
	if bad_bin == "" do return
	_ = os.write_entire_file(fmt.tprintf("%s/%s/Contents/Resources/integrations/data.txt", bad, CORE_APP), transmute([]byte)string("changed\n"))
	_, ok3, why3 := holder_install(bad_bin, data)
	testing.expectf(t, !ok3 && strings.contains(why3, "signature"), "a changed resource: refused (%s)", why3)
	// signed, but not as the holder
	other := fmt.tprintf("%s/other", d)
	other_bin := lt_core_app(t, other, "dev.example.other", 2)
	if other_bin == "" do return
	_, ok4, why4 := holder_install(other_bin, data)
	testing.expectf(t, !ok4, "another identifier: refused (%s)", why4)
	// only the good install is left: no temp dirs
	entries, _ := os.read_all_directory_by_path(fmt.tprintf("%s/core", data), context.temp_allocator)
	testing.expectf(t, len(entries) == 1, "left in core/: %d entries", len(entries))
}

// The direct spawn: `bin hold --run --data`, in a session of its own, stdin /dev/null, output to
// <run>/holder.log, nothing blocked.
@(test)
holder_direct_spawn :: proc(t: ^testing.T) {
	d := lt_dir("direct")
	defer os.remove_all(d)
	run := fmt.tprintf("%s/run", d)
	data := fmt.tprintf("%s/data", d)
	os.make_directory_all(run)
	bin := fmt.tprintf("%s/fake-holder", d)
	script := "#!/bin/sh\necho \"args: $*\"\necho \"pgid: $(ps -o pgid= -p $$ | tr -d ' ') pid: $$\"\necho \"env: $LT_MARK\"\nread x && echo \"stdin: $x\" || echo 'stdin: eof'\necho done >&2\n"
	_ = os.write_entire_file(bin, transmute([]byte)script)
	posix.chmod(strings.clone_to_cstring(bin, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	pid, ok, why := holder_launch_direct(bin, run, data, {"LT_MARK=yes", "PATH=/usr/bin:/bin"})
	if !testing.expectf(t, ok, "spawned: %s", why) do return
	log := fmt.tprintf("%s/%s", run, HOLDER_LOG)
	text: string
	for _ in 0 ..< 200 {
		b, _ := os.read_entire_file(log, context.temp_allocator)
		text = string(b)
		if strings.contains(text, "done") do break
		time.sleep(10 * time.Millisecond)
	}
	testing.expect(t, strings.contains(text, fmt.tprintf("args: hold --run %s --data %s", run, data)), text)
	testing.expect(t, strings.contains(text, fmt.tprintf("pgid: %d pid: %d", pid, pid)), text) // setsid: its own group
	testing.expect(t, strings.contains(text, "env: yes"), text)
	testing.expect(t, strings.contains(text, "stdin: eof"), text)
	testing.expect(t, strings.contains(text, "done"), "stderr goes to the log too")
}

@(private = "file")
lt_launchd_ok :: proc() -> bool {
	_, st := run_group({"/bin/launchctl", "print", fmt.tprintf("gui/%d", posix.getuid())}, 10 * time.Second)
	return st == .Ok
}

@(private = "file")
lt_loaded :: proc(label: string) -> bool {
	_, st := run_group({"/bin/launchctl", "print", fmt.tprintf("gui/%d/%s", posix.getuid(), label)}, 10 * time.Second)
	return st == .Ok
}

// The job as §6 has it: Interactive, RunAtLoad, no KeepAlive, the group abandoned, escaped.
@(test)
launchd_plist_keys :: proc(t: ^testing.T) {
	p := launchd_plist("dev.deckhand.test.1.2", "/A & B/<deckhand-core>", "/r", "/d", "/r/job-abcdef")
	wants := []string{
		"<key>Label</key><string>dev.deckhand.test.1.2</string>",
		"<array><string>/A &amp; B/&lt;deckhand-core&gt;</string><string>__detach</string><string>--run</string><string>/r</string><string>--data</string><string>/d</string><string>--ready</string><string>ready</string></array>",
		"<key>WorkingDirectory</key><string>/r/job-abcdef</string>",
		"<key>StandardInPath</key><string>/dev/null</string>",
		"<key>StandardErrorPath</key><string>/r/holder.log</string>",
		"<key>ProcessType</key><string>Interactive</string>",
		"<key>RunAtLoad</key><true/>",
		"<key>KeepAlive</key><false/>",
		"<key>AbandonProcessGroup</key><true/>",
	}
	for want in wants do testing.expectf(t, strings.contains(p, want), "missing %s", want)
	testing.expect_value(t, launchd_parse_pid("123\n"), i32(123))
	for bad in ([]string{"", "\n", "123", "-4\n", "x\n", "99999999999\n"}) do testing.expect_value(t, launchd_parse_pid(bad), i32(0))
}

// One real launch through launchd (S2's path): the detached holder runs with parent launchd
// after its job was booted out, the temp dir is gone, and a stale job and temp dir of a dead
// launcher are swept. Skipped without a GUI session (CI, ssh).
//
// First the real holder started directly (test mode's way): it leaves its cwd (the app's) for "/",
// so it never keeps a directory or a volume busy.
@(test)
launchd_launch_real :: proc(t: ^testing.T) {
	d := lt_dir("ld")
	defer os.remove_all(d)
	run := fmt.tprintf("%s/run", d)
	data := fmt.tprintf("%s/data", d)
	testing.expect_value(t, runtime_dir_prepare(run, RUNTIME_HOLDER_NEED), "")
	os.make_directory_all(data)
	domain := fmt.tprintf("gui/%d", posix.getuid())

	// the holder: src/holder built here (a second; the launchd job must exec a real binary)
	bin := fmt.tprintf("%s/deckhand-core", d)
	o, bst := run_group({"odin", "build", "src/holder", fmt.tprintf("-out:%s", bin), "-minimum-os-version:14.0"}, 120 * time.Second, merge_stderr = true)
	if !testing.expectf(t, bst == .Ok, "odin build src/holder: %s", o) do return
	// as build.sh signs it (ad hoc here, as this test binary is: the launcher checks its identifier, P8)
	co, cst := run_group({"/usr/bin/codesign", "-f", "-s", "-", "-i", HOLDER_ID, bin}, 30 * time.Second, merge_stderr = true)
	if !testing.expectf(t, cst == .Ok, "codesign: %s", co) do return

	{
		drun := fmt.tprintf("%s/drun", d)
		testing.expect_value(t, runtime_dir_prepare(drun, RUNTIME_HOLDER_NEED), "")
		dpid, dok, dwhy := holder_launch_direct(bin, drun, data, {"PATH=/usr/bin:/bin"})
		if !testing.expectf(t, dok, "direct: %s", dwhy) do return
		defer posix.kill(posix.pid_t(dpid), .SIGKILL)
		listening := false
		for _ in 0 ..< 300 {
			entries, _ := os.read_all_directory_by_path(drun, context.temp_allocator)
			for e in entries do if strings.has_prefix(e.name, "holder-") && strings.has_suffix(e.name, ".sock") do listening = true
			if listening do break
			time.sleep(10 * time.Millisecond)
		}
		testing.expect(t, listening, "the direct holder never listened")
		lo, lst := run_group({"/usr/sbin/lsof", "-a", "-p", fmt.tprintf("%d", dpid), "-d", "cwd", "-Fn"}, 10 * time.Second)
		testing.expectf(t, lst == .Ok && strings.contains(lo, "\nn/\n"), "the direct holder's cwd is not /: %q", lo)
	}

	if !lt_launchd_ok() {
		fmt.println("launchd_launch_real: launchd part skipped (no gui/<uid> launchd domain: not a GUI session)")
		return
	}

	// a dead launcher's leftovers: a loaded job that ran and ended (/usr/bin/true) with an old
	// stamp, a fresh one of the same kind, and an old temp dir
	old_label := fmt.tprintf("%s%d.%d", TEST_LABEL_PREFIX, posix.getpid(), time.now()._nsec - i64(2 * LAUNCHD_STALE_AGE))
	new_label := fmt.tprintf("%s%d.%d", TEST_LABEL_PREFIX, posix.getpid(), time.now()._nsec)
	defer launchd_bootout(domain, old_label)
	defer launchd_bootout(domain, new_label)
	for l in ([]string{old_label, new_label}) {
		pl := fmt.tprintf("%s/%s.plist", d, l)
		_ = os.write_entire_file(pl, transmute([]byte)fmt.tprintf(`<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Label</key><string>%s</string><key>ProgramArguments</key><array><string>/usr/bin/true</string></array><key>RunAtLoad</key><true/><key>KeepAlive</key><false/></dict></plist>
`, l))
		o, st := run_group({"/bin/launchctl", "bootstrap", domain, pl}, 10 * time.Second, merge_stderr = true)
		testing.expectf(t, st == .Ok, "bootstrap %s: %s", l, o)
		os.remove(pl)
	}
	old_dir := fmt.tprintf("%s/%sdead01", run, LAUNCHD_JOB_DIR)
	fresh_dir := fmt.tprintf("%s/%sbusy02", run, LAUNCHD_JOB_DIR)
	os.make_directory(old_dir)
	os.make_directory(fresh_dir)
	_ = os.write_entire_file(fmt.tprintf("%s/job.plist", old_dir), transmute([]byte)string("x"))
	tv := [2]posix.timeval{{tv_sec = posix.time_t(time.now()._nsec / 1e9 - 3600)}, {tv_sec = posix.time_t(time.now()._nsec / 1e9 - 3600)}}
	posix.utimes(strings.clone_to_cstring(old_dir, context.temp_allocator), &tv)
	time.sleep(100 * time.Millisecond) // /usr/bin/true has run and ended

	t0 := time.tick_now()
	pid, label, ok, why := launchd_launch(bin, run, data, {"LT_MARK=yes", "PATH=/usr/bin:/bin"}, TEST_LABEL_PREFIX)
	elapsed := time.tick_since(t0)
	defer if label != "" do launchd_bootout(domain, label)
	defer if pid > 0 {
		posix.kill(posix.pid_t(pid), .SIGKILL)
	}
	if !testing.expectf(t, ok, "launched: %s (%s)", why, label) do return
	fmt.printfln("launchd_launch_real: launched pid %d in %v", pid, elapsed)
	testing.expect_value(t, pid_parent(pid), i32(1))
	testing.expect_value(t, launchd_realpath(holder_pid_exe(pid)), launchd_realpath(bin))
	testing.expect(t, !lt_loaded(label), "its job was booted out")
	time.sleep(50 * time.Millisecond)
	testing.expect(t, posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK, "and it survived the bootout")
	// the sweep at its start
	testing.expect(t, !lt_loaded(old_label), "an old stale job is booted out")
	testing.expect(t, lt_loaded(new_label), "a young one is left")
	testing.expect(t, !os.exists(old_dir), "an old temp dir is removed")
	testing.expect(t, os.exists(fresh_dir), "a young one is left")
	// its own temp dir is gone
	entries, _ := os.read_all_directory_by_path(run, context.temp_allocator)
	for e in entries do testing.expectf(t, !strings.has_prefix(e.name, LAUNCHD_JOB_DIR) || e.name == "job-busy02", "left: %s", e.name)

	// the same holder signed with another identifier: the launcher refuses it before the
	// environment (P8: its code, by the token from accept), and the launch fails
	swapped := fmt.tprintf("%s/swapped/deckhand-core", d)
	os.make_directory_all(fmt.tprintf("%s/swapped", d))
	sb, _ := os.read_entire_file(bin, context.temp_allocator)
	_ = os.write_entire_file(swapped, sb)
	posix.chmod(strings.clone_to_cstring(swapped, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	so, sst := run_group({"/usr/bin/codesign", "-f", "-s", "-", "-i", "dev.deckhand.swapped", swapped}, 30 * time.Second, merge_stderr = true)
	if !testing.expectf(t, sst == .Ok, "codesign: %s", so) do return
	saved := holder_ready_timeout
	holder_ready_timeout = 3 * time.Second
	defer holder_ready_timeout = saved
	spid, slabel, sok, swhy := launchd_launch(swapped, run, data, {"LT_MARK=yes", "PATH=/usr/bin:/bin"}, TEST_LABEL_PREFIX)
	defer if slabel != "" do launchd_bootout(domain, slabel)
	defer if spid > 0 do posix.kill(posix.pid_t(spid), .SIGKILL)
	testing.expectf(t, !sok && spid == 0, "a swapped holder is refused: %v %d %s", sok, spid, swhy)
	log, _ := os.read_entire_file(fmt.tprintf("%s/%s", run, HOLDER_LOG), context.temp_allocator)
	testing.expectf(t, strings.contains(string(log), "ready:"), "the refused holder saw no environment: %q", string(log))
}

// A bootstrap that fails (or times out) may still have loaded the job: it is booted out on
// every path after the attempt. A stand-in launchctl records the calls; launchd is not touched.
@(test)
launchd_bootout_after_failed_bootstrap :: proc(t: ^testing.T) {
	d := lt_dir("lfail")
	defer os.remove_all(d)
	run := fmt.tprintf("%s/run", d)
	testing.expect_value(t, runtime_dir_prepare(run, RUNTIME_HOLDER_NEED), "")
	calls := fmt.tprintf("%s/calls", d)
	fake := fmt.tprintf("%s/launchctl", d)
	script := fmt.tprintf("#!/bin/sh\necho \"$*\" >> '%s'\nif [ \"$1\" = bootstrap ]; then echo 'Bootstrap failed: 5: Input/output error' >&2; exit 5; fi\nexit 0\n", calls)
	_ = os.write_entire_file(fake, transmute([]byte)script)
	posix.chmod(strings.clone_to_cstring(fake, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	_, label, ok, why := launchd_launch("/nonexistent/deckhand-core", run, fmt.tprintf("%s/data", d), {"PATH=/usr/bin:/bin"}, TEST_LABEL_PREFIX, launchctl = fake)
	testing.expectf(t, !ok && strings.contains(why, "bootstrap"), "a failed bootstrap: %v %s", ok, why)
	b, _ := os.read_entire_file(calls, context.temp_allocator)
	want := fmt.tprintf("bootout gui/%d/%s", posix.getuid(), label)
	testing.expectf(t, strings.contains(string(b), want), "no %q in the calls: %q", want, string(b))
}

// holder_install's temp file: unique per call (the update's helper install and an upgrade's can
// run at once on two threads of one process: a pid-only name made one remove the other's).
@(test)
holder_install_tmp_unique :: proc(t: ^testing.T) {
	a := holder_install_tmp("/d")
	b := holder_install_tmp("/d")
	testing.expect(t, a != b, a)
	testing.expect(t, strings.has_prefix(a, "/d/.deckhand-core.") && strings.has_suffix(a, ".tmp"), a)
}
