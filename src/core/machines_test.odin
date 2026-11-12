package core

// Other machines over SSH (machines.odin; §10.4 M6-A): the registry, the ssh argv, the status
// table and the backoff, as pure procs (no ssh runs). The hub door's refusals are in
// window_sock_test.odin; the link itself in tests/scripts/remote-link.sh.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"

import cw "../corewire"

@(test)
machines_registry_round_trip :: proc(t: ^testing.T) {
	dir := fmt.tprintf("%s/dkm-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.make_directory(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/%s", dir, MACHINES_FILE)
	none, next0, ok0 := machines_read(path, context.temp_allocator)
	testing.expect(t, ok0 && len(none) == 0 && next0 == 1, "no file: none, numbers from 1")
	list := []Machine {
		{no = 1, name = "NUC \"lab\"", target = "me@nuc", os = "linux", arch = "amd64", core_path = machine_core_path_for("linux")},
		{no = 3, name = "mini", target = "mini", via = "build/deckhand-core-serve connect"},
	}
	testing.expect_value(t, machines_write(path, list, 4), "")
	st: posix.stat_t
	testing.expect(t, posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK)
	testing.expectf(t, u32(transmute(posix._mode_t)st.st_mode) & 0o777 == 0o600, "mode %o", u32(transmute(posix._mode_t)st.st_mode) & 0o777)
	got, next, ok := machines_read(path, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect_value(t, next, u64(4))
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], list[0])
		testing.expect_value(t, got[1], list[1])
	}
	// written again over the old one: still 0600
	testing.expect_value(t, machines_write(path, list[:1], 4), "")
	testing.expect(t, posix.stat(strings.clone_to_cstring(path, context.temp_allocator), &st) == .OK)
	testing.expect(t, u32(transmute(posix._mode_t)st.st_mode) & 0o777 == 0o600, "0600 after a rewrite")
	_ = os.write_entire_file(path, transmute([]u8)string("{not json"))
	_, _, bad := machines_read(path, context.temp_allocator)
	testing.expect(t, !bad, "a broken file is not read as empty")
}

@(test)
machines_ssh_argv :: proc(t: ^testing.T) {
	run := "/Users/someone/Library/Application Support/Deckhand/run"
	m := Machine{no = 7, name = "nuc", target = "me@nuc", os = "darwin", arch = "arm64", core_path = machine_core_path_for("darwin")}
	argv, why := machine_argv(m, run, "Some-Mac.local")
	testing.expect_value(t, why, "")
	joined := strings.join(argv, " ", context.temp_allocator)
	testing.expect_value(t, argv[0], "ssh")
	for o in ([?]string{"-o BatchMode=yes", "-o ControlMaster=auto", "-o ControlPersist=600", "-o Compression=yes"}) do testing.expectf(t, strings.contains(joined, o), "%s in %s", o, joined)
	ctl := ""
	for a, i in argv do if a == "-S" && i + 1 < len(argv) do ctl = argv[i + 1]
	testing.expect(t, strings.has_suffix(ctl, "/ssh-7.ctl"), ctl)
	testing.expectf(t, len(ctl) <= MACHINE_CTL_MAX, "ControlPath %d bytes", len(ctl))
	n := len(argv)
	testing.expect(t, argv[n - 3] == "--" && argv[n - 2] == "me@nuc", "the target after --, as its own argument")
	testing.expect_value(t, argv[n - 1], `"$HOME/Library/Application Support/Deckhand/core/current/Deckhand Core.app/Contents/MacOS/deckhand-core-serve" connect --from Some-Mac`)
	probe, pwhy := machine_argv({no = 7, target = "me@nuc"}, run, "x", probe = true)
	testing.expect(t, pwhy == "" && probe[len(probe) - 1] == "uname -sm", "the probe")
	// a run dir that would pass the ControlPath limit is refused, not truncated
	_, why = machine_argv(m, strings.concatenate({run, "/a-much-longer-folder-name"}, context.temp_allocator), "x")
	testing.expect(t, strings.contains(why, "control socket"), why)
	// what the user typed never becomes an option or reaches a shell
	for bad in ([?]string{"-oProxyCommand=touch /tmp/x", "a;b", "host name", "$(id)", "a`b`", "h'q"}) {
		x := m
		x.target = bad
		_, why = machine_argv(x, run, "x")
		testing.expectf(t, why != "", "target %q refused", bad)
	}
	x := m
	x.core_path = "~/evil\"; rm -rf ~"
	_, why = machine_argv(x, run, "x")
	testing.expect(t, why != "", "a core path Deckhand does not know is refused")
	testing.expect_value(t, machine_from_name("Jo's Mac;rm.local"), "Jo-s-Mac-rm")
	// --via: test builds only
	v := Machine{no = 2, name = "m2", via = "env A=1 build/deckhand-core-serve connect"}
	va, vwhy := machine_argv(v, run, "Some-Mac", test_build = true)
	testing.expect_value(t, vwhy, "")
	testing.expect_value(t, strings.join(va, " ", context.temp_allocator), "env A=1 build/deckhand-core-serve connect --from Some-Mac")
	_, vwhy = machine_argv(v, run, "Some-Mac", test_build = false)
	testing.expect(t, strings.contains(vwhy, "only for development and test builds"), vwhy)
	// uname -sm
	os_name, arch, uok := machine_uname_parse("Linux x86_64\n")
	testing.expect(t, uok && os_name == "linux" && arch == "amd64", "linux")
	_, _, uok = machine_uname_parse("FreeBSD amd64")
	testing.expect(t, !uok, "not a Mac or Linux")
}

@(test)
machines_status_table :: proc(t: ^testing.T) {
	cases := []struct {
		o:    Machine_Outcome,
		want: Machine_Status,
	} {
		{{replied = true, ok = true, skew = .Ok}, .Online},
		{{replied = true, ok = true, skew = .Core_Older}, .Online},
		{{replied = true, ok = true, skew = .Core_Below_Min}, .Needs_Update},
		{{replied = true, ok = true, skew = .Core_Older_Generation}, .Needs_Update},
		{{replied = true, ok = true, skew = .Core_Newer_Generation}, .Needs_Update},
		{{replied = true, ok = false, error = "framed mode is only for Deckhand's window (with the core's window token)"}, .Offline},
		{{exited = true, exit_code = 255, stderr = "me@nuc: Permission denied (publickey,password).\r\n"}, .Needs_Login},
		{{exited = true, exit_code = 255, stderr = "Host key verification failed.\n"}, .Needs_Login},
		{{exited = true, exit_code = 255, stderr = "ssh: connect to host nuc port 22: Connection refused\n"}, .Offline},
		{{exited = true, exit_code = 1, stderr = "Permission denied"}, .Offline}, // not ssh's own failure
		{{exited = true, exit_code = 127, stderr = "zsh:1: no such file or directory: /Users/me/Library/…"}, .Not_Installed},
		{{stderr = "no answer from its core"}, .Offline},
	}
	for c, i in cases {
		got, why := machine_status_of(c.o)
		testing.expectf(t, got == c.want, "case %d: %v, want %v (%s)", i, got, c.want, why)
	}
	_, why := machine_status_of({exited = true, exit_code = 255, stderr = "debug1: x\nssh: connect to host nuc port 22: Connection refused\n"})
	testing.expect_value(t, why, "ssh: connect to host nuc port 22: Connection refused")
	_, why = machine_status_of({replied = true, ok = false, error = "the hub must run as this user"})
	testing.expect_value(t, why, "the hub must run as this user")
	_ = cw.GENERATION
}

@(test)
machines_backoff_fake_clock :: proc(t: ^testing.T) {
	b: Machine_Backoff
	now := time.Tick{_nsec = 1_000_000_000_000}
	want := []time.Duration{1, 2, 4, 8, 16, 32, 60, 60}
	for w in want {
		got := machine_backoff_down(&b, now)
		testing.expect_value(t, got, w * time.Second)
		now = time.tick_add(now, got)
	}
	// up for 30 s: still backing off
	machine_backoff_up(&b, now)
	testing.expect_value(t, machine_backoff_down(&b, time.tick_add(now, 30 * time.Second)), 60 * time.Second)
	// up for a minute: back to 1 s, then doubling again
	machine_backoff_up(&b, now)
	now = time.tick_add(now, MACHINE_UP_RESET)
	testing.expect_value(t, machine_backoff_down(&b, now), time.Second)
	testing.expect_value(t, machine_backoff_down(&b, now), 2 * time.Second)
}

// Review round 1 (PR #69): what comes before the answer (a remote rc file's output) is skipped,
// a link that sends too much without one fails at once (no busy poll), and the probe has a deadline.
@(test)
machines_scan_round1 :: proc(t: ^testing.T) {
	// the probe: the first line uname -sm could have printed
	os_name, arch, ok := machine_probe_answer("Welcome to the lab\nLast login: today\nDarwin arm64\n")
	testing.expect(t, ok && os_name == "darwin" && arch == "arm64", "past an rc file's lines")
	_, _, ok = machine_probe_answer("hello there\n")
	testing.expect(t, !ok, "no answer")
	// the hello reply: the first line that is a JSON object; the frames start after it
	text := "motd line\n\n{\"id\":\"hub\",\"result\":{\"ok\":true}}\nFRAMES"
	s, line, rest := machine_hello_scan(transmute([]u8)text, 1 << 20)
	testing.expect_value(t, s, Machine_Scan.Found)
	testing.expect_value(t, line, `{"id":"hub","result":{"ok":true}}`)
	testing.expect_value(t, text[rest:], "FRAMES")
	s, _, _ = machine_hello_scan(transmute([]u8)string("motd\n{\"id\""), 1 << 20)
	testing.expect_value(t, s, Machine_Scan.Wait)
	// the cap: fail now, not wait (its fd would stay readable and the loop would spin)
	big := make([]u8, 64, context.temp_allocator)
	for &b in big do b = 'x'
	s, _, _ = machine_hello_scan(big, 64)
	testing.expect_value(t, s, Machine_Scan.Too_Long)
	testing.expect(t, MACHINE_PROBE_WAIT == 30 * time.Second, "the probe's deadline")
	// this core's id rides along, so the other end can refuse a core that is its own hub
	run := "/Users/someone/Library/Application Support/Deckhand/run"
	id := strings.repeat("0f", 32, context.temp_allocator)
	m := Machine{no = 7, name = "nuc", target = "me@nuc", os = "darwin", arch = "arm64", core_path = machine_core_path_for("darwin")}
	argv, why := machine_argv(m, run, "Some-Mac", core_id = id)
	testing.expect_value(t, why, "")
	testing.expect(t, strings.has_suffix(argv[len(argv) - 1], fmt.tprintf("connect --from Some-Mac --core %s", id)), argv[len(argv) - 1])
	_, why = machine_argv(m, run, "Some-Mac", core_id = "x'; id")
	testing.expect(t, why != "", "a core id is hex only")
	v := Machine{no = 2, name = "m2", via = "build/deckhand-core-serve connect"}
	va, _ := machine_argv(v, run, "Some-Mac", core_id = id, test_build = true)
	testing.expect_value(t, strings.join(va, " ", context.temp_allocator), fmt.tprintf("build/deckhand-core-serve connect --from Some-Mac --core %s", id))
}

// The setting that opens the hub door: off by default, the user's only at this Mac (never a hub's).
@(test)
machines_reachable_setting :: proc(t: ^testing.T) {
	testing.expect(t, !machines_reachable_default_on, "off by default")
	found := false
	for e in COMMAND_SPECS do if e.type == "set_machines_reachable" {
		found = true
		testing.expect_value(t, e.who, Command_Who.User_Here)
	}
	testing.expect(t, found, "set_machines_reachable is a command")
}

// Review round 2 (PR #69): the hello reply's machine.os and .arch are kept only when they are
// values uname -sm gives (darwin|linux, arm64|amd64); anything else leaves the old ones.
@(test)
machines_hello_os_arch :: proc(t: ^testing.T) {
	hostile := strings.concatenate({strings.repeat("a", 300, context.temp_allocator), "‮gnp"}, context.temp_allocator)
	o, a := machine_os_arch_from_hello(hostile, "arm64", "darwin", "arm64")
	testing.expect(t, o == "darwin" && a == "arm64", "a hostile os leaves both")
	o, a = machine_os_arch_from_hello("linux", "⁦x86", "darwin", "arm64")
	testing.expect(t, o == "darwin" && a == "arm64", "a hostile arch leaves both")
	o, a = machine_os_arch_from_hello("linux", "amd64", "darwin", "arm64")
	testing.expect(t, o == "linux" && a == "amd64", "known values are taken")
}
