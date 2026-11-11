package core

// Install and update of another machine's core (machine_install.odin; §10.4 M6-E): the shared ssh
// argv, the install plan, the Update button's rule, the remote scripts (run here by /bin/sh, a
// stand-in for the other machine's login shell), the Linux tarball's checks, and a job through
// its children with /bin/sh in place of ssh. No ssh runs; the scene remote-install.sh installs
// through a test build's `via` machine.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import cw "../corewire"
import usig "../updatesig"

// A release build compiles _test files too: these use hook-only helpers.
when TEST_HOOKS {

@(private = "file")
tmp_dir :: proc(tag: string) -> string {
	base := strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/")
	if base == "" do base = "/tmp"
	d := fmt.tprintf("%s/dkmi-%s-%d-%d", base, tag, posix.getpid(), time.now()._nsec % 1_000_000_000)
	os.make_directory_all(d)
	return d
}

@(private = "file")
sh :: proc(script: string, args: ..string) -> (out: string, code: int) {
	argv := make([dynamic]string, context.temp_allocator)
	append(&argv, "/bin/sh", "-c", script, "t")
	for a in args do append(&argv, a)
	o, st := run_group(argv[:], 30 * time.Second, merge_stderr = true)
	if st == .Ok do return o, 0
	return o, 1
}

@(test)
ssh_argv_modes :: proc(t: ^testing.T) {
	ctl := "/r/ssh-3.ctl"
	pinned := []string{"-o ForkAfterAuthentication=no", "-o RequestTTY=no", "-o BatchMode=yes", "-o ForwardAgent=no", "-o ForwardX11=no", "-o PermitLocalCommand=no", "-o ServerAliveInterval=15", "-o ServerAliveCountMax=4"}
	mux, why := ssh_argv("me@nuc", .Mux, ctl, remote = "sh -c 'x' dh 0123456789abcdef")
	testing.expect_value(t, why, "")
	want := []string{"ssh", "-S", ctl, "-o", "ControlMaster=no", "-o", "ControlPersist=no", "-o", "ForkAfterAuthentication=no", "-o", "RequestTTY=no", "-o", "BatchMode=yes", "-o", "ClearAllForwardings=yes", "-o", "ForwardAgent=no", "-o", "ForwardX11=no", "-o", "PermitLocalCommand=no", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=4", "--", "me@nuc", "sh -c 'x' dh 0123456789abcdef"}
	testing.expectf(t, strings.join(mux, " ", context.temp_allocator) == strings.join(want, " ", context.temp_allocator), "mux %v", mux)
	// the link's master: the same pins, its own control options, no forwards
	m := Machine{no = 3, name = "nuc", target = "me@nuc", os = "linux", arch = "amd64", core_path = machine_core_path_for("linux")}
	link, lwhy := machine_argv(m, "/r", "Mac")
	testing.expect_value(t, lwhy, "")
	j := strings.join(link, " ", context.temp_allocator)
	for p in pinned do testing.expectf(t, strings.contains(j, p), "%s in %s", p, j)
	for p in ([]string{"-o ControlMaster=auto", "-o ControlPersist=600", "-o ClearAllForwardings=yes", "-o Compression=yes"}) do testing.expectf(t, strings.contains(j, p), "%s in %s", p, j)
	// the target is checked and goes after --; a control path is needed but for Forward
	for bad in ([]string{"-oProxyCommand=x", "a b", "a;b", ""}) {
		_, w := ssh_argv(bad, .Mux, ctl)
		testing.expectf(t, w != "", "target %q refused", bad)
	}
	_, w := ssh_argv("me@nuc", .Mux, "")
	testing.expect(t, w != "", "a mux call needs the control path")
	_, w = ssh_argv("me@nuc", .Master, strings.repeat("x", MACHINE_CTL_MAX + 1, context.temp_allocator))
	testing.expect(t, w != "", "a long control path is refused")
}

@(test)
machine_install_plan_test :: proc(t: ^testing.T) {
	k, why := machine_install_plan("darwin", "arm64", "darwin", "arm64")
	testing.expect(t, why == "" && k == .Copy_App, "another Mac of this arch: the Core.app")
	k, why = machine_install_plan("darwin", "arm64", "linux", "amd64")
	testing.expect(t, why == "" && k == .Tarball, "Linux x86_64: the tarball")
	_, why = machine_install_plan("darwin", "arm64", "linux", "arm64")
	testing.expect(t, why != "", "Linux arm64: none yet")
	_, why = machine_install_plan("darwin", "arm64", "darwin", "amd64")
	testing.expect(t, why != "", "an Intel Mac: none")
	_, why = machine_install_plan("linux", "amd64", "linux", "amd64")
	testing.expect(t, why != "", "installs run from a Mac")
	_, why = machine_install_plan("darwin", "arm64", "", "")
	testing.expect(t, why != "", "an OS not known yet")
}

@(test)
machine_update_offer_test :: proc(t: ^testing.T) {
	testing.expect_value(t, machine_update_offer("0.3.0", "0.2.1", .Online, .Core_Older, true), Update_Offer.Button)
	testing.expect_value(t, machine_update_offer("0.3.0", "0.2.1", .Online, .Core_Older, false), Update_Offer.Command_Only) // outside its folder (or an older core that does not say)
	testing.expect_value(t, machine_update_offer("0.3.0", "0.3.0", .Online, .Ok, true), Update_Offer.None)
	testing.expect_value(t, machine_update_offer("0.3.0", "0.4.0", .Online, .Ok, true), Update_Offer.None) // never a downgrade
	testing.expect_value(t, machine_update_offer("", "0.2.1", .Online, .Ok, true), Update_Offer.None) // a development build compares nothing
	testing.expect_value(t, machine_update_offer("0.3.0", "0.1.0", .Needs_Update, .Core_Below_Min, true), Update_Offer.Button)
	testing.expect_value(t, machine_update_offer("0.3.0", "0.2.5", .Needs_Update, .Core_Older_Generation, true), Update_Offer.Button)
	testing.expect_value(t, machine_update_offer("0.3.0", "0.9.0", .Needs_Update, .Core_Older_Generation, true), Update_Offer.None)
	testing.expect_value(t, machine_update_offer("0.3.0", "0.4.0", .Needs_Update, .Core_Newer_Generation, true), Update_Offer.None) // update this Mac instead
	testing.expect_value(t, machine_update_offer("0.3.0", "0.1.0", .Needs_Update, .Core_Below_Min, false), Update_Offer.Command_Only)
	testing.expect_value(t, machine_update_offer("0.3.0", "", .Not_Installed, .Ok, false), Update_Offer.None) // Install…, not Update
	testing.expect_value(t, machine_update_offer("0.3.0", "0.1.0", .Offline, .Ok, true), Update_Offer.None)
}

// The remote commands: fixed text and checked arguments; the scripts refuse anything else before
// they touch a file, and remove only their own staging dir.
@(test)
machine_install_scripts :: proc(t: ^testing.T) {
	for s in ([]string{MACHINE_INSTALL_SCRIPT_MAC, MACHINE_INSTALL_SCRIPT_LINUX}) {
		testing.expect(t, !strings.contains_any(s, "'!\n"), "one line, no single quote, no !")
	}
	nonce := "0123456789abcdef"
	r, why := machine_install_remote("darwin", .Copy_App, nonce, "")
	testing.expect(t, why == "" && strings.has_prefix(r, "sh -c '") && strings.has_suffix(r, "' dh 0123456789abcdef"), r)
	r, why = machine_install_remote("linux", .Tarball, nonce, "0.3.0")
	testing.expect(t, why == "" && strings.has_suffix(r, "' dh 0123456789abcdef 0.3.0"), r)
	_, why = machine_install_remote("linux", .Tarball, nonce, "")
	testing.expect(t, why != "", "a development build has no tarball")
	for bad in ([]string{"", "0123456789ABCDEF", "0123456789abcde", "../../../../x", "0123456789abcdeg"}) {
		_, why = machine_install_remote("darwin", .Copy_App, bad, "")
		testing.expectf(t, why != "", "nonce %q refused", bad)
	}
	_, why = machine_install_remote("linux", .Copy_App, nonce, "")
	testing.expect(t, why != "", "a Core.app goes only to a Mac")
	c, cwhy := machine_cleanup_remote("linux", nonce)
	testing.expect(t, cwhy == "" && strings.contains(c, `.incoming-$n"`) && strings.has_suffix(c, "' dh 0123456789abcdef"), c)

	// the scripts themselves, under /bin/sh with a fake HOME
	home := tmp_dir("home")
	defer remove_tree(home)
	data := fmt.tprintf("%s/.local/share/deckhand", home)
	for args in ([][]string{{}, {""}, {"x;rm -rf ~"}, {"$(id)"}, {"0123456789abcdef", "1.2;id"}, {"0123456789abcdef", ""}}) {
		_, code := sh(fmt.tprintf(`HOME="%s"; export HOME; %s`, home, MACHINE_INSTALL_SCRIPT_LINUX), ..args)
		testing.expectf(t, code != 0, "args %v refused", args)
		testing.expectf(t, !os.exists(data), "args %v: nothing made", args)
	}
	// a good run: the archive unpacked into .incoming-<nonce>, its install run, the dir removed
	top := core_tarball_top("0.3.0")
	src := tmp_dir("src")
	defer remove_tree(src)
	os.make_directory_all(fmt.tprintf("%s/%s", src, top))
	fake := fmt.tprintf("%s/%s/%s", src, top, CORE_SERVE_BIN)
	_ = os.write_entire_file(fake, transmute([]u8)string("#!/bin/sh\necho \"deckhand-core-serve install: linger is off\" >&2\necho \"$@\" > \"$HOME/args\"\nls -d \"$HOME\"/.local/share/deckhand/core/.incoming-* > \"$HOME/staging\"\n"))
	posix.chmod(strings.clone_to_cstring(fake, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	tgz := fmt.tprintf("%s/t.tar.gz", src)
	_, tcode := sh(`tar -czf "$1" -C "$2" "$3"`, tgz, src, top)
	testing.expect_value(t, tcode, 0)
	os.make_directory_all(fmt.tprintf("%s/core/.incoming-ffffffffffffffff", data)) // another run's: left alone
	out, code := sh(fmt.tprintf(`HOME="%s"; export HOME; exec < "$3"; %s`, home, MACHINE_INSTALL_SCRIPT_LINUX), nonce, "0.3.0", tgz)
	testing.expectf(t, code == 0, "the install ran: %s", out)
	args, _ := os.read_entire_file(fmt.tprintf("%s/args", home), context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(args)), fmt.tprintf("install --data %s --allow-hubs", data))
	staging, _ := os.read_entire_file(fmt.tprintf("%s/staging", home), context.temp_allocator)
	testing.expect(t, strings.contains(string(staging), ".incoming-0123456789abcdef"), "it ran from its staging dir")
	testing.expect(t, !os.exists(fmt.tprintf("%s/core/.incoming-%s", data, nonce)), "its staging dir is gone")
	testing.expect(t, os.exists(fmt.tprintf("%s/core/.incoming-ffffffffffffffff", data)), "another run's staging dir is left alone")
	// the cleanup removes that nonce's dir only
	os.make_directory_all(fmt.tprintf("%s/core/.incoming-%s", data, nonce))
	cl, _ := machine_cleanup_remote("linux", nonce)
	_, code = sh(fmt.tprintf(`HOME="%s"; export HOME; eval "$1"`, home), cl)
	testing.expect_value(t, code, 0)
	testing.expect(t, !os.exists(fmt.tprintf("%s/core/.incoming-%s", data, nonce)) && os.exists(fmt.tprintf("%s/core/.incoming-ffffffffffffffff", data)), "the cleanup removes its own dir only")
	testing.expect_value(t, machine_linger_answer("motd\non\n"), Linger.On)
	testing.expect_value(t, machine_linger_answer("off\n"), Linger.Off)
	testing.expect_value(t, machine_linger_answer("yes\n"), Linger.Unknown)
}

// The Linux tarball, checked here before it is copied: its size, sha256 and .sig (v3, cdhash
// none), then its names and the unpacked tree.
@(test)
machine_tarball_checks :: proc(t: ^testing.T) {
	seed, pub, ok := usig.generate()
	testing.expect(t, ok, "a key")
	v := "0.3.0"
	name, top := core_tarball_name(v), core_tarball_top(v)
	testing.expect_value(t, name, "deckhand-core-0.3.0-linux-x86_64.tar.gz")
	d := tmp_dir("tgz")
	defer remove_tree(d)
	os.make_directory_all(fmt.tprintf("%s/src/%s/pi", d, top))
	_ = os.write_entire_file(fmt.tprintf("%s/src/%s/%s", d, top, CORE_SERVE_BIN), transmute([]u8)string("elf"))
	_ = os.write_entire_file(fmt.tprintf("%s/src/%s/pi/x.js", d, top), transmute([]u8)string("js"))
	tgz := fmt.tprintf("%s/%s", d, name)
	_, code := sh(`tar -czf "$1" -C "$2" "$3"`, tgz, fmt.tprintf("%s/src", d), top)
	testing.expect_value(t, code, 0)
	sum, size, _ := usig.file_sha256(tgz)
	sign :: proc(seed, v, name: string, size: i64, sum: string) -> string {
		m := usig.manifest(v, name, size, sum, "none", context.temp_allocator, .V3)
		s, _ := usig.sign(seed, transmute([]byte)m)
		return fmt.tprintf("%s\ncdhash none\nsignature %s\n", usig.SIG_FILE_HEAD_V3, s)
	}
	good := sign(seed, v, name, size, sum)
	testing.expect_value(t, tarball_verify(tgz, good, v, size, pub), "")
	testing.expect(t, tarball_verify(tgz, good, v, size + 1, pub) != "", "not the release's size")
	testing.expect(t, tarball_verify(tgz, sign(seed, "0.2.9", core_tarball_name("0.2.9"), size, sum), v, size, pub) != "", "another version's signature")
	other_seed, _, _ := usig.generate()
	testing.expect(t, tarball_verify(tgz, sign(other_seed, v, name, size, sum), v, size, pub) != "", "another key's signature")
	testing.expect(t, tarball_verify(tgz, sign(seed, v, name, size, strings.repeat("0", 64, context.temp_allocator)), v, size, pub) != "", "a sha256 mismatch")
	testing.expect(t, tarball_verify(tgz, strings.concatenate({usig.SIG_FILE_HEAD, "\ncdhash none\nsignature x\n"}, context.temp_allocator), v, size, pub) != "", "v2 never with none")
	testing.expect(t, tarball_verify(tgz, "", v, size, pub) != "", "no signature")
	// the names
	testing.expect_value(t, tarball_names_check(fmt.tprintf("%s/\n%s/deckhand-core-serve\n", top, top), top), "")
	for bad in ([]string{"/etc/passwd\n", fmt.tprintf("%s/../../x\n", top), "other/x\n", ""}) do testing.expectf(t, tarball_names_check(bad, top) != "", "listing %q refused", bad)
	// the tree: links of any kind refused
	x := fmt.tprintf("%s/x", d)
	_, code = sh(`mkdir -p "$1" && tar -xzf "$2" -C "$1"`, x, tgz)
	testing.expect_value(t, tarball_tree_check(x, top), "")
	posix.symlink("/etc", strings.clone_to_cstring(fmt.tprintf("%s/%s/pi/l", x, top), context.temp_allocator))
	testing.expect(t, strings.contains(tarball_tree_check(x, top), "link"), "a symlink is refused")
	os.remove(fmt.tprintf("%s/%s/pi/l", x, top))
	posix.link(strings.clone_to_cstring(fmt.tprintf("%s/%s/pi/x.js", x, top), context.temp_allocator), strings.clone_to_cstring(fmt.tprintf("%s/%s/pi/h.js", x, top), context.temp_allocator))
	testing.expect(t, strings.contains(tarball_tree_check(x, top), "hard link"), "a hard link is refused")
	// the release's JSON
	rel := fmt.tprintf(`{{"assets":[{{"name":"%s","size":%d}},{{"name":"%s.sig","size":150}}]}}`, name, size, name)
	got, why := core_tarball_release_size(rel, name)
	testing.expect(t, why == "" && got == size, why)
	_, why = core_tarball_release_size(fmt.tprintf(`{{"assets":[{{"name":"%s","size":%d}}]}}`, name, size), name)
	testing.expect(t, why != "", "no .sig: refused")
	_, why = core_tarball_release_size(fmt.tprintf(`{{"assets":[{{"name":"%s","size":%d}},{{"name":"%s.sig","size":150}}]}}`, name, TARBALL_MAX + 1, name), name)
	testing.expect(t, why != "", "over the cap: refused")
}

// A machine to install to: a via machine (its "remote" is a fake HOME here) on a fresh registry.
@(private = "file")
Inst_Fixture :: struct {
	dir, home: string,
	no:        u64,
	saved_root: string,
	saved_sep, saved_on: bool,
}

@(private = "file")
fixture_up :: proc(t: ^testing.T) -> (f: Inst_Fixture) {
	f.dir = tmp_dir("job")
	f.home = fmt.aprintf("%s/home", f.dir)
	os.make_directory_all(f.home)
	f.saved_root, f.saved_sep, f.saved_on = home_root, core_separate, state.settings.remote_machines
	home_root = fmt.aprintf("%s/data", f.dir)
	os.make_directory_all(home_root)
	core_separate, state.settings.remote_machines = true, true
	machines_load()
	r := machine_add_apply({name = "m2", via = "true"})
	testing.expect(t, r.ok, r.error)
	f.no = r.created_id
	install_here_for_test = {"darwin", "arm64"}
	return
}

@(private = "file")
fixture_down :: proc(f: ^Inst_Fixture) {
	machine_install_reset_for_test()
	machines_reset_for_test()
	remove_tree(f.dir)
	home_root, core_separate, state.settings.remote_machines = f.saved_root, f.saved_sep, f.saved_on
}

@(private = "file")
tick_until :: proc(no: u64, want: Machine_Job, wait := 20 * time.Second) -> Machine_Job {
	deadline := time.tick_add(time.tick_now(), wait)
	for {
		machine_install_tick(time.tick_now())
		p, _, _, _, _ := machine_install_job_for_test(no)
		if p == want || time.tick_diff(time.tick_now(), deadline) <= 0 do return p
		time.sleep(10 * time.Millisecond)
	}
}

// Install… on another Mac: the Core.app tarred to the "remote" script, which runs its install;
// the next hello from this Mac's version ends the job. Darwin: the copy is bsdtar's.
@(test)
machine_install_job :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	f := fixture_up(t)
	defer fixture_down(&f)
	app := fmt.tprintf("%s/core/Deckhand Core.app", f.dir)
	os.make_directory_all(fmt.tprintf("%s/Contents/MacOS", app))
	serve := fmt.tprintf("%s/Contents/MacOS/%s", app, CORE_SERVE_BIN)
	_ = os.write_entire_file(serve, transmute([]u8)string("#!/bin/sh\necho \"$@\" > \"$HOME/args\"\necho \"$0\"\n"))
	posix.chmod(strings.clone_to_cstring(serve, context.temp_allocator), {.IRUSR, .IWUSR, .IXUSR})
	install_app_for_test, install_skip_dr_for_test = app, true
	install_ssh_for_test = {"/bin/sh", "-c", fmt.tprintf(`HOME="%s" exec /bin/sh -c "$1"`, f.home), "ssh"}
	// only the user, never a hub, never with the setting off
	r := machine_install_apply({no = f.no}, {kind = .Control})
	testing.expect(t, !r.ok, "control may not install")
	machine_status_set_for_test(f.no, .Online, "0.3.0", installed = true)
	r = machine_install_apply({no = f.no}, {kind = .UI})
	testing.expect(t, !r.ok, "nothing to install on an online machine of the same version")
	machine_status_set_for_test(f.no, .Not_Installed)
	r = machine_install_apply({no = f.no}, {kind = .UI})
	testing.expectf(t, r.ok, "install: %s", r.error)
	r = machine_install_apply({no = f.no}, {kind = .UI})
	testing.expect(t, !r.ok, "one install per machine at a time")
	got := tick_until(f.no, .Handing_Over)
	_, note, _, _, _ := machine_install_job_for_test(f.no)
	testing.expectf(t, got == .Handing_Over, "copied and installed: %v %s", got, note)
	args, _ := os.read_entire_file(fmt.tprintf("%s/args", f.home), context.temp_allocator)
	testing.expect_value(t, strings.trim_space(string(args)), fmt.tprintf("install --data %s/Library/Application Support/Deckhand", f.home))
	entries, _ := os.read_all_directory_by_path(fmt.tprintf("%s/Library/Application Support/Deckhand/core", f.home), context.temp_allocator)
	testing.expect_value(t, len(entries), 0) // its staging dir went
	// an older core's hello gets the handover (once); this Mac's version ends it
	testing.expect(t, machine_install_hello(f.no, "0.1.0", true), "the old core is told to hand over")
	testing.expect(t, !machine_install_hello(f.no, "0.1.0", true), "...once")
	machine_install_hello(f.no, core_version(), true)
	p, _, _, sent, _ := machine_install_job_for_test(f.no)
	testing.expect(t, p == .Done && sent, "done on the new core's hello")
	entries, _ = os.read_all_directory_by_path(upath(home_root, INSTALL_DIR), context.temp_allocator)
	testing.expect_value(t, len(entries), 0) // no local temp dir left
}

// Cancel mid-copy: the copy's process group ends (SIGTERM, then SIGKILL), the remote cleanup
// runs, and the job fails; a core outside Deckhand's folder is never handed over.
@(test)
machine_install_cancel :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	f := fixture_up(t)
	defer fixture_down(&f)
	app := fmt.tprintf("%s/core/Deckhand Core.app", f.dir)
	os.make_directory_all(fmt.tprintf("%s/Contents/MacOS", app))
	_ = os.write_entire_file(fmt.tprintf("%s/Contents/MacOS/%s", app, CORE_SERVE_BIN), transmute([]u8)string("x"))
	install_app_for_test, install_skip_dr_for_test = app, true
	// the install hangs (and ignores SIGTERM); the cleanup runs and leaves a mark
	install_ssh_for_test = {"/bin/sh", "-c", fmt.tprintf(`case "$1" in *"install --data"*) trap "" TERM; echo $$ > %[0]s/pid; cat > /dev/null; exec sleep 60;; *) HOME="%[0]s" exec /bin/sh -c "$1; touch \"\$HOME/cleaned\"";; esac`, f.home), "ssh"}
	machine_status_set_for_test(f.no, .Not_Installed)
	r := machine_install_apply({no = f.no}, {kind = .UI})
	testing.expectf(t, r.ok, "install: %s", r.error)
	testing.expect_value(t, tick_until(f.no, .Copying), Machine_Job.Copying)
	_, _, copied, _, pid := machine_install_job_for_test(f.no)
	testing.expect(t, copied && pid > 1, "the copy runs")
	time.sleep(100 * time.Millisecond)
	start := time.tick_now()
	machine_install_apply({no = f.no, cancel = true}, {kind = .UI})
	got := tick_until(f.no, .Failed, 10 * time.Second)
	_, note, _, _, _ := machine_install_job_for_test(f.no)
	testing.expectf(t, got == .Failed && note == "cancelled", "%v %s", got, note)
	took := time.tick_since(start)
	testing.expectf(t, took < 8 * time.Second, "it ended (took %v)", took)
	testing.expect(t, posix.kill(pid, .SIGCONT) != .OK, "the copy's leader is gone (reaped)")
	// the stand-in ignored SIGTERM: its group's SIGKILL took it too
	hp, _ := os.read_entire_file(fmt.tprintf("%s/pid", f.home), context.temp_allocator)
	hpid, _ := strconv.parse_int(strings.trim_space(string(hp)))
	testing.expect(t, hpid > 1 && posix.kill(posix.pid_t(hpid), .SIGCONT) != .OK, "the stand-in that ignored SIGTERM is gone")
	testing.expect(t, os.exists(fmt.tprintf("%s/cleaned", f.home)), "the remote cleanup ran")
	// a hello from a core outside Deckhand's folder: never told to hand over
	machine_status_set_for_test(f.no, .Online, "0.1.0", installed = false, skew = cw.Skew.Core_Older)
	testing.expect(t, !machine_install_hello(f.no, "0.1.0", false), "no handover outside the folder")
	// removed: the job goes
	machine_install_drop(f.no, removed = true)
	p, _, _, _, _ := machine_install_job_for_test(f.no)
	testing.expect_value(t, p, Machine_Job.None)
}

// The Linux grant: taken once, only a regular 0600 file of this user's.
@(test)
machine_grant_marker :: proc(t: ^testing.T) {
	d := tmp_dir("grant")
	defer remove_tree(d)
	p := fmt.tprintf("%s/%s", d, MACHINES_GRANT_FILE)
	cp := strings.clone_to_cstring(p, context.temp_allocator)
	fd := posix.open(cp, {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
	posix.close(fd)
	testing.expect(t, machines_grant_take_at(p), "a 0600 file is taken")
	testing.expect(t, !os.exists(p) && !machines_grant_take_at(p), "...once")
	fd = posix.open(cp, {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR, .IROTH})
	posix.close(fd)
	posix.chmod(cp, {.IRUSR, .IWUSR, .IROTH})
	testing.expect(t, !machines_grant_take_at(p) && !os.exists(p), "readable by others: refused, removed")
	other := fmt.tprintf("%s/other", d)
	fd = posix.open(strings.clone_to_cstring(other, context.temp_allocator), {.WRONLY, .CREAT, .EXCL}, {.IRUSR, .IWUSR})
	posix.close(fd)
	posix.symlink(strings.clone_to_cstring(other, context.temp_allocator), cp)
	testing.expect(t, !machines_grant_take_at(p), "a link is never followed")
	testing.expect(t, os.exists(other), "...nor what it points at removed")
	// the commands are the user's only
	for name in ([]string{"machine_install", "machine_linger"}) {
		for s in COMMAND_SPECS do if s.type == name do testing.expectf(t, s.who == .User, "%s is user-only", name)
	}
}

// ---- review round 1 ----

// (1) A command a hub queued keeps where it came from: refused even once that hub is gone (an
// oversized frame detaches it before the inbox runs the command).
@(test)
r1_hub_provenance :: proc(t: ^testing.T) {
	f := fixture_up(t)
	defer fixture_down(&f)
	machine_status_set_for_test(f.no, .Not_Installed)
	testing.expect(t, !window_link_hub(), "no hub attached now")
	hub := Caller{kind = .UI, hub = true}
	r := machine_install_apply({no = f.no}, hub)
	testing.expect(t, !r.ok && strings.contains(r.error, "viewed from another"), r.error)
	r = machine_linger_apply({no = f.no}, hub)
	testing.expect(t, !r.ok && strings.contains(r.error, "viewed from another"), r.error)
	r, _ = machine_open_page_apply({no = f.no, port = 3000}, hub, 0)
	testing.expect(t, !r.ok && strings.contains(r.error, "viewed from another"), r.error)
	// what a hub link's command is read as
	v, _ := json.parse_string(`{"on_behalf":{"kind":"ui"}}`, allocator = context.temp_allocator)
	c, ok := hub_on_behalf(v.(json.Object))
	testing.expect(t, ok && c.kind == .UI && c.hub, "a hub's ui command carries hub")
	p, _, _, _, _ := machine_install_job_for_test(f.no)
	testing.expect_value(t, p, Machine_Job.None)
}

// (2) A child's output is read at most CHILD_READ_BUDGET bytes per turn, the first ones kept.
@(test)
r1_read_budget :: proc(t: ^testing.T) {
	p: [2]posix.FD
	testing.expect(t, posix.pipe(&p) == .OK, "a pipe")
	defer {posix.close(p[0]); posix.close(p[1])}
	posix.fcntl(p[0], .SETFL, posix.fcntl(p[0], .GETFL) | posix.O_NONBLOCK)
	posix.fcntl(p[1], .SETFL, posix.fcntl(p[1], .GETFL) | posix.O_NONBLOCK)
	chunk: [4096]u8
	for &b in chunk do b = 'x'
	written := 0
	for written < 60 << 10 {
		n := posix.write(p[1], &chunk[0], len(chunk))
		if n <= 0 do break
		written += int(n)
	}
	keep: [100]u8
	kept := 0
	got, eof := pipe_drain(p[0], keep[:], &kept, 16 << 10)
	testing.expectf(t, got == 16 << 10 && !eof && kept == 100, "one turn: %d read, %d kept", got, kept)
	got, _ = pipe_drain(p[0], keep[:], &kept, 16 << 10)
	testing.expect(t, got == 16 << 10 && kept == 100, "the next turn: the next budget, nothing more kept")
	testing.expect(t, CHILD_READ_BUDGET <= 256 << 10, "a small budget per turn")
}

// (3) After the copy, an up link's core gets core_handover only if its hello (now) said it is of
// Deckhand's own folder: another core may have connected meanwhile.
@(test)
r1_handover_rechecks_installed :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	f := fixture_up(t)
	defer fixture_down(&f)
	fake_app(f.dir, "")
	install_ssh_for_test = {"/bin/sh", "-c", `cat > /dev/null; exit 0`, "ssh"}
	machine_status_set_for_test(f.no, .Needs_Update, "0.1.0", installed = true, skew = cw.Skew.Core_Below_Min)
	machine_test_links.on = true
	machine_test_links.up = make(map[u64]bool)
	machine_test_links.up[f.no] = true
	defer {
		machine_test_links.on = false
		for x in machine_test_links.texts do delete(x)
		clear(&machine_test_links.texts)
		delete(machine_test_links.up)
	}
	r := machine_install_apply({no = f.no}, {kind = .UI})
	testing.expectf(t, r.ok, "update: %s", r.error)
	testing.expect_value(t, tick_until(f.no, .Copying), Machine_Job.Copying)
	machine_status_set_for_test(f.no, .Online, "0.1.5", installed = false) // another core came up meanwhile
	got := tick_until(f.no, .Failed)
	testing.expect_value(t, got, Machine_Job.Failed)
	for x in machine_test_links.texts do testing.expectf(t, !strings.contains(x, "core_handover"), "never sent to it: %s", x)
}

// (4) A compatible older core's hello (Online) gets the handover too: one sender for both.
// (5) The job waits for the copied app's version (core/current's), not the running core's.
@(test)
r1_online_hello_and_version :: proc(t: ^testing.T) {
	when ODIN_OS != .Darwin do return
	f := fixture_up(t)
	defer fixture_down(&f)
	fake_app(f.dir, "0.4.0")
	install_ssh_for_test = {"/bin/sh", "-c", `cat > /dev/null; exit 0`, "ssh"}
	machine_status_set_for_test(f.no, .Not_Installed)
	r := machine_install_apply({no = f.no}, {kind = .UI})
	testing.expectf(t, r.ok, "install: %s", r.error)
	testing.expect_value(t, tick_until(f.no, .Handing_Over), Machine_Job.Handing_Over)
	// an Online hello from an older core of Deckhand's own: the frame goes on that link
	line := `{"result":{"ok":true,"data":{"framed":true,"generation":1,"version":"0.2.5","machine":{"os":"darwin","arch":"arm64","installed":true}}}}`
	sent := machine_hello_for_test(f.no, line)
	testing.expectf(t, strings.contains(sent, `"core_handover"`) && strings.contains(sent, `"current"`), "sent: %q", sent)
	// the running core's version ("" here) is not what was copied
	machine_install_hello(f.no, core_version(), true)
	p, _, _, _, _ := machine_install_job_for_test(f.no)
	testing.expect_value(t, p, Machine_Job.Handing_Over)
	machine_install_hello(f.no, "0.4.0", true)
	p, _, _, _, _ = machine_install_job_for_test(f.no)
	testing.expect_value(t, p, Machine_Job.Done)
	// never a downgrade: the copied 0.4.0 to a 0.5.0 of an older generation
	machine_status_set_for_test(f.no, .Needs_Update, "0.5.0", installed = true, skew = cw.Skew.Core_Older_Generation)
	r = machine_install_apply({no = f.no}, {kind = .UI})
	got := r.ok ? tick_until(f.no, .Failed) : .Failed
	_, note, _, _, _ := machine_install_job_for_test(f.no)
	testing.expectf(t, got == .Failed && (strings.contains(note, "downgrade") || strings.contains(r.error, "downgrade")), "%v %s %s", got, note, r.error)
}

// (6) machine_add's automatic install is armed for its first finding only.
@(test)
r1_auto_install_once :: proc(t: ^testing.T) {
	f := fixture_up(t)
	defer fixture_down(&f)
	machine_outcome_for_test(f.no, {exited = true, exit_code = 255, stderr = "ssh: connect to host nuc port 22: Connection refused"})
	machine_outcome_for_test(f.no, {exited = true, exit_code = 127})
	p, _, _, _, _ := machine_install_job_for_test(f.no)
	testing.expect_value(t, p, Machine_Job.None)
}

@(private = "file")
fake_app :: proc(dir, version: string) {
	app := fmt.tprintf("%s/core/Deckhand Core.app", dir)
	os.make_directory_all(fmt.tprintf("%s/Contents/MacOS", app))
	_ = os.write_entire_file(fmt.tprintf("%s/Contents/MacOS/%s", app, CORE_SERVE_BIN), transmute([]u8)string("x"))
	if version != "" {
		_ = os.write_entire_file(fmt.tprintf("%s/Contents/Info.plist", app), transmute([]u8)fmt.tprintf(`<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleShortVersionString</key><string>%s</string></dict></plist>`, version))
	}
	install_app_for_test, install_skip_dr_for_test = strings.clone(app), true
}

} // when TEST_HOOKS
