package core

// Starting the session holder outside the app (docs/plans/background-core.md §6, herdr's
// launchd model as the S2 spike proved it on macOS 26.6.2). A direct child would stay in the
// app's coalition; a launchd job gets its own from the start.
//
//   1. A 0700 temp dir <run>/job-<rand6> with job.plist (0600) and the ready socket. The label
//      is unique per launch, <prefix><pid>.<ns>: a fixed one fails while loaded (S2).
//   2. `launchctl bootstrap gui/<uid> job.plist`, then the plist is removed. RunAtLoad, no
//      KeepAlive (never `launchctl submit`: that makes a KeepAlive job), AbandonProcessGroup,
//      ProcessType Interactive (it sticks through fork, exec and bootout).
//   3. The job runs `deckhand-core __detach hold ...` (src/holder/detach.odin): fork, the
//      parent exits, the child calls setsid and execs `hold --ready`, which waits for ppid 1.
//   4. The child connects to ready and sends its pid. The launcher checks the peer
//      (trust.ready_peer_allowed: the socket's process is that pid, of this user; then its code
//      by the token read at accept, trust.peer_dr_check: the holder's designated requirement,
//      P8), that its parent is launchd and that it runs bin; boots the job out (that kills only
//      the job's own process, long gone); then sends the environment (it carries tokens), and
//      reads the ack.
//
// A launcher killed between bootstrap and bootout leaks a loaded job that never runs again:
// every launch first sweeps our labels that are not running and older than a minute, and
// abandoned temp dirs. A failed bootstrap or handshake falls back to the direct spawn
// (holder_install.odin), with a logged warning.
//
//   holder_launch(bin, run, data, env) -> (pid, ok, why)   the entry the app calls

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"

import "../trust"

// The labels this app's launches use. Tests use "dev.deckhand.test." and boot out every job.
holder_label_prefix := "dev.deckhand.hold."
// How long the launcher waits for the detached child's pid, and then for its ack.
holder_ready_timeout := 10 * time.Second
LAUNCHCTL :: "/bin/launchctl" // tests pass a stand-in to launchd_launch
LAUNCHD_STALE_AGE :: 60 * time.Second // a job or temp dir this old is a dead launcher's
LAUNCHD_JOB_DIR :: "job-" // <run>/job-<6 hex>: short, the ready socket's path must fit in sun_path

// Starts a session holder for run (the runtime dir) and data (the data dir), running bin (from
// holder_install), with env ("KEY=VALUE"; nil = this process's). Test mode and
// DECKHAND_HOLDER_DIRECT=1 spawn it directly and never touch launchd. pid: the holder's.
holder_launch :: proc(bin, run, data: string, env: []string) -> (pid: i32, ok: bool, why: string) {
	if len(run) + RUNTIME_HOLDER_NEED > SUN_PATH_MAX {
		return 0, false, fmt.tprintf("the runtime dir %s is too long for the session holder's socket (sun_path is %d bytes)", run, SUN_PATH_MAX + 1)
	}
	if autotest_active || hook_env(.Holder_Direct) == "1" do return holder_launch_direct(bin, run, data, env)
	lpid, _, lok, lwhy := launchd_launch(bin, run, data, env, holder_label_prefix)
	if lok do return lpid, true, ""
	fmt.eprintln("Deckhand: session holder: the launchd launch failed:", lwhy, "- starting it directly")
	return holder_launch_direct(bin, run, data, env)
}

// The launchd path alone (tests call it with their prefix). label: the job's, booted out on
// return whatever happened.
launchd_launch :: proc(bin, run, data: string, env: []string, prefix: string, launchctl := LAUNCHCTL, mode := "hold") -> (pid: i32, label: string, ok: bool, why: string) {
	launchd_sweep(run, prefix, launchctl)
	uid := posix.getuid()
	label = fmt.tprintf("%s%d.%d", prefix, posix.getpid(), time.now()._nsec)
	domain := fmt.tprintf("gui/%d", uid)
	jdir := ""
	for _ in 0 ..< 8 {
		r: [3]u8
		crypto.rand_bytes(r[:])
		d := fmt.tprintf("%s/%s%02x%02x%02x", run, LAUNCHD_JOB_DIR, r[0], r[1], r[2])
		if posix.mkdir(strings.clone_to_cstring(d, context.temp_allocator), posix.S_IRWXU) == .OK {
			jdir = d
			break
		}
	}
	if jdir == "" do return 0, label, false, fmt.tprintf("cannot make a temp dir in %s: %s", run, posix.strerror(posix.errno()))
	ready := fmt.tprintf("%s/ready", jdir)
	plist := fmt.tprintf("%s/job.plist", jdir)
	defer {
		sock_unlink(ready)
		os.remove(plist)
		os.remove(jdir)
	}
	lfd, lok := sock_listen(ready)
	if !lok do return 0, label, false, fmt.tprintf("cannot listen on %s", ready)
	defer sock_close(lfd)
	if w := launchd_write_plist(plist, launchd_plist(label, bin, run, data, jdir, mode)); w != "" do return 0, label, false, w
	// a bootstrap that failed or timed out may still have loaded the job: booted out on every path
	booted := false
	defer if !booted do launchd_bootout(domain, label, launchctl)
	out, st := run_group({launchctl, "bootstrap", domain, plist}, 10 * time.Second, merge_stderr = true)
	os.remove(plist)
	if st != .Ok do return 0, label, false, fmt.tprintf("launchctl bootstrap: %v %s", st, strings.trim_space(out))

	exe := launchd_realpath(bin)
	deadline := time.tick_now()._nsec + i64(holder_ready_timeout)
	for {
		left := int((deadline - time.tick_now()._nsec) / i64(time.Millisecond))
		if left <= 0 do return 0, label, false, "the detached holder never connected to the ready socket"
		cfd, aok := sock_accept(lfd, left)
		if !aok do continue
		p, w := launchd_ready_serve(cfd, exe, env, domain, label, &booted, deadline, launchctl)
		sock_close(cfd)
		if p > 0 do return p, label, true, ""
		fmt.eprintln("Deckhand: session holder: ready:", w)
		if booted do return 0, label, false, w // the real child was answered and failed
	}
}

// One connection on the ready socket: "" and the pid once the child acked, else why not. The job
// is booted out (booted set) once the peer passed, before the environment goes.
@(private = "file")
launchd_ready_serve :: proc(cfd: Sock_Fd, exe: string, env: []string, domain, label: string, booted: ^bool, deadline: i64, launchctl: string) -> (pid: i32, why: string) {
	at_accept, tok := trust.peer_read_token(cfd) // before any byte is read
	line, lok := launchd_read_until(cfd, '\n', 32, deadline)
	if !lok do return 0, "no pid from the peer"
	claimed := launchd_parse_pid(line)
	if d := trust.ready_peer_allowed(.Adhoc, trust.own_uid(), claimed, at_accept); d != .Allow do return 0, fmt.tprintf("refused a peer (%v)", d)
	// its code, by the token from accept (§5.3 P8): the holder's designated requirement
	if d, got := trust.peer_dr_check(tok, trust.CORE_IDS); d != .Allow do return 0, fmt.tprintf("refused pid %d: its code: %v (identifier %q, status %d)", claimed, d, got.identifier, got.status)
	if pp := pid_parent(claimed); pp != 1 do return 0, fmt.tprintf("refused pid %d: its parent is %d, not launchd", claimed, pp)
	if got := launchd_realpath(holder_pid_exe(claimed)); exe == "" || got != exe do return 0, fmt.tprintf("refused pid %d: it runs %q, not %q", claimed, got, exe)
	launchd_bootout(domain, label, launchctl)
	booted^ = true
	if d := trust.peer_still(at_accept, trust.peer_read(cfd)); d != .Allow do return 0, fmt.tprintf("the peer changed before the environment (%v)", d)
	sent := env
	if sent == nil do sent, _ = os.environ(context.temp_allocator) // nil: ours
	b := strings.builder_make(context.temp_allocator)
	for e in sent {
		if e == "" || strings.contains_rune(e, 0) do continue
		strings.write_string(&b, e)
		strings.write_byte(&b, 0)
	}
	strings.write_byte(&b, 0)
	if !sock_write_all(cfd, b.buf[:]) do return 0, "the holder left before the environment"
	ack, aok := launchd_read_until(cfd, '\n', 8, deadline)
	// (no peer check after the ack: the holder may have closed its end, and then the token is
	// unreadable; the ack only ends the launch, it decides nothing)
	if !aok || ack != "ok\n" {
		// it has the environment but did not finish: stop it, or the fallback would make two
		// (only while the socket still shows that very process: never a reused pid)
		if trust.peer_still(at_accept, trust.peer_read(cfd)) == .Allow do posix.kill(posix.pid_t(claimed), .SIGKILL)
		return 0, "no ack from the holder"
	}
	return claimed, ""
}

// Reads up to and including end (at most max bytes), before deadline (tick ns).
@(private = "file")
launchd_read_until :: proc(fd: Sock_Fd, end: u8, max: int, deadline: i64) -> (string, bool) {
	buf := make([dynamic]u8, context.temp_allocator)
	one: [1]u8
	for len(buf) < max {
		left := int((deadline - time.tick_now()._nsec) / i64(time.Millisecond))
		if left <= 0 || !sock_wait_readable(fd, left) do return "", false
		if sock_read(fd, one[:]) != 1 do return "", false
		append(&buf, one[0])
		if one[0] == end do return string(buf[:]), true
	}
	return "", false
}

// "<pid>\n" from the detached child (src/holder/detach.odin): 0 = bad.
launchd_parse_pid :: proc(line: string) -> i32 {
	if !strings.has_suffix(line, "\n") do return 0
	s := line[:len(line) - 1]
	n, pok := strconv.parse_int(s, 10)
	if !pok || n <= 0 || n > int(max(i32)) do return 0
	return i32(n)
}

launchd_realpath :: proc(p: string) -> string {
	if p == "" do return ""
	r := posix.realpath(strings.clone_to_cstring(p, context.temp_allocator), nil)
	if r == nil do return ""
	defer posix.free(r)
	return strings.clone(string(r), context.temp_allocator)
}

holder_pid_exe :: proc(pid: i32) -> string {
	buf: [4096]u8
	n := proc_pidpath(i32(pid), &buf[0], u32(len(buf))) // pty_posix.odin's
	if n <= 0 do return ""
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

launchd_bootout :: proc(domain, label: string, launchctl := LAUNCHCTL) {
	out, st := run_group({launchctl, "bootout", fmt.tprintf("%s/%s", domain, label)}, 10 * time.Second, merge_stderr = true)
	// gone already (it never loaded, or a sweep raced us) is fine; anything else is worth a line
	if st != .Ok && !strings.contains(out, "No such process") && !strings.contains(out, "Could not find service") {
		fmt.eprintln("Deckhand: session holder: launchctl bootout", label, ":", strings.trim_space(out))
	}
}

// The job (docs/plans/background-core.md §6). WorkingDirectory is the temp dir, so the ready
// socket goes by its short relative name; the child makes it absolute and leaves for "/".
launchd_plist :: proc(label, bin, run, data, jdir: string, mode := "hold") -> string {
	x := launchd_xml
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprint(&b, `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
`)
	fmt.sbprintf(&b, "  <key>Label</key><string>%s</string>\n", x(label))
	fmt.sbprint(&b, "  <key>ProgramArguments</key><array>")
	// a separate core: `__detach serve` (src/coremain), else the holder's `__detach` (hold)
	args := mode == "serve" ? []string{bin, "__detach", "serve", "--run", run, "--data", data, "--ready", "ready"} : []string{bin, "__detach", "--run", run, "--data", data, "--ready", "ready"}
	for a in args do fmt.sbprintf(&b, "<string>%s</string>", x(a))
	fmt.sbprint(&b, "</array>\n")
	fmt.sbprintf(&b, "  <key>WorkingDirectory</key><string>%s</string>\n", x(jdir))
	fmt.sbprint(&b, "  <key>StandardInPath</key><string>/dev/null</string>\n")
	logp := x(fmt.tprintf("%s/%s", run, mode == "serve" ? CORE_LOG : HOLDER_LOG))
	fmt.sbprintf(&b, "  <key>StandardOutPath</key><string>%s</string>\n", logp)
	fmt.sbprintf(&b, "  <key>StandardErrorPath</key><string>%s</string>\n", logp)
	fmt.sbprint(&b, `  <key>ProcessType</key><string>Interactive</string>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>AbandonProcessGroup</key><true/>
  <key>Umask</key><integer>63</integer>
</dict></plist>
`)
	return strings.to_string(b)
}

@(private = "file")
launchd_xml :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch r {
		case '&': strings.write_string(&b, "&amp;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case '"': strings.write_string(&b, "&quot;")
		case: strings.write_rune(&b, r)
		}
	}
	return strings.to_string(b)
}

@(private = "file")
launchd_write_plist :: proc(path, body: string) -> string {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .CREAT, .EXCL, .NOFOLLOW, .CLOEXEC}, {.IRUSR, .IWUSR})
	if fd < 0 do return fmt.tprintf("cannot write %s: %s", path, posix.strerror(posix.errno()))
	defer posix.close(fd)
	if posix.write(fd, raw_data(body), len(body)) != len(body) do return fmt.tprintf("cannot write %s", path)
	return ""
}

// herdr's remove_stale: boot out our labels (prefix) that are not running and whose ns stamp is
// older than LAUNCHD_STALE_AGE (a launcher died between bootstrap and bootout), and remove temp
// dirs in run that old (their launcher is gone: one waits 10 s at most).
launchd_sweep :: proc(run, prefix: string, launchctl := LAUNCHCTL) {
	now := time.now()._nsec
	out, st := run_group({launchctl, "list"}, 10 * time.Second)
	if st == .Ok {
		domain := fmt.tprintf("gui/%d", posix.getuid())
		for line in strings.split_lines(out, context.temp_allocator) {
			f := strings.split(line, "\t", context.temp_allocator)
			if len(f) != 3 || f[0] != "-" || !strings.has_prefix(f[2], prefix) do continue
			// <prefix><pid>.<ns>
			_, _, ns_s := strings.partition(f[2][len(prefix):], ".")
			ns, nok := strconv.parse_i64(ns_s, 10)
			if !nok || now - ns < i64(LAUNCHD_STALE_AGE) do continue
			launchd_bootout(domain, f[2], launchctl)
		}
	}
	entries, err := os.read_all_directory_by_path(run, context.temp_allocator)
	if err != nil do return
	for e in entries {
		if !strings.has_prefix(e.name, LAUNCHD_JOB_DIR) || len(e.name) != len(LAUNCHD_JOB_DIR) + 6 do continue
		st: posix.stat_t
		d := fmt.tprintf("%s/%s", run, e.name)
		if posix.lstat(strings.clone_to_cstring(d, context.temp_allocator), &st) != .OK || !posix.S_ISDIR(st.st_mode) do continue
		if now - (i64(st.st_mtim.tv_sec) * 1e9 + i64(st.st_mtim.tv_nsec)) < i64(LAUNCHD_STALE_AGE) do continue
		// only what a launch puts there; anything else keeps the dir (and is not ours to remove)
		sock_unlink(fmt.tprintf("%s/ready", d))
		os.remove(fmt.tprintf("%s/job.plist", d))
		os.remove(d)
	}
}

// The labels a separate core's launches use (deckhand-core serve).
core_label_prefix := "dev.deckhand.core."

// Starts a separate core (`deckhand-core serve`, src/coremain) for run and data, as the holder is
// started: through launchd (its own coalition), or directly in test mode and with
// DECKHAND_HOLDER_DIRECT=1, or when the launchd launch fails. pid: the core's. Its environment
// is this process's without what Deckhand sets for a tab (core_launch_env): `deckhand --ctl` run
// in a tab launches one too, and the core must not carry that tab's tokens, socket or ids.
// from_tab (`deckhand --ctl`): Claude Code's settings (CLAUDE_CONFIG_DIR…) go too, as the login
// environment's merge drops them (login_env.odin): an agent's shell is not the user's.
core_launch :: proc(bin, run, data: string, from_tab := false) -> (pid: i32, ok: bool, why: string) {
	ours, _ := os.environ(context.temp_allocator)
	env := core_launch_env(ours, from_tab)
	if autotest_active || hook_env(.Holder_Direct) == "1" do return holder_launch_direct(bin, run, data, env, "serve")
	lpid, _, lok, lwhy := launchd_launch(bin, run, data, env, core_label_prefix, mode = "serve")
	if lok do return lpid, true, ""
	fmt.eprintln("Deckhand: background core: the launchd launch failed:", lwhy, "- starting it directly")
	return holder_launch_direct(bin, run, data, env, "serve")
}

// env without the names Deckhand sets for its tabs, jobs and control callers, under either name
// (env_tab_dropped: the same scrub a tab's own environment gets). Temp allocator.
core_launch_env :: proc(env: []string, from_tab := false) -> []string {
	out := make([dynamic]string, 0, len(env), context.temp_allocator)
	for e in login_env_strip_claude(env, from_tab) do if !env_tab_dropped(env_key(e)) do append(&out, e)
	return out[:]
}
