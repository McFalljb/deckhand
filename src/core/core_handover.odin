package core

// A separate core hands its sessions over to another core process (docs/plans/background-core.md
// §7.2 with a core process on each side, §7.4 M4+, §10.3 M4-E).
//
//   core_handover{to}   (the window: an update, Use this app's core, Use previous core)
//     1. the target: <data>/core/current or previous (core_versions.odin; test builds also take
//        "self", this binary), checked: its signature (holder_verify) and `check` (generation,
//        snapshot formats). Refused: nothing changes.
//     2. job runs get JOBS_HANDOVER_WAIT to end (none starts meanwhile), then the core quits
//        by SIGTERM (as for a stop; never platform.quit, which tells windows to quit), with the
//        handover named:
//   serve_stop (src/coremain)
//     3. the runs still going stop as "stopped (update)"; GOODBYE{handover, successor}: every held
//        terminal fed to its acked offset and snapshotted there (holder_handover), handover.json,
//        the workspace flushed; the window's link and core.sock closed;
//   core_handover_finish
//     4. both locks released, then the successor launched with the holder's secret (over the
//        peer-checked ready socket, or a pipe when spawned directly); it says HELLO{secret}, adopts
//        from handover.json and serves. A launch that fails falls back to this core's own binary,
//        with the same secret, so the sessions are never left without a core for long (the holder
//        keeps them either way; its reservation lapses after 60 s).
//
// The window's connection ends at step 3; it dials core.sock again (client_core.odin).

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:time"

JOBS_HANDOVER_WAIT :: 2 * time.Minute

@(private = "file")
handover: struct {
	to:      string, // the target serve binary (heap); "" = none under way
	until:   time.Tick, // job runs are waited for until then
	formats: []string, // the snapshot formats the target reads (heap)
	quit:    bool, // platform.quit was called for it
}

when ODIN_TEST {
	// Tests: a handover under way, or none.
	core_handover_pending_set :: proc(on: bool) {
		delete(handover.to)
		handover.to = on ? strings.clone("/test/deckhand-core-serve") : ""
	}
}

// This process is a separate core (deckhand-core-serve: coremain sets it).
core_separate: bool

// A handover is under way: job runs wait (job_start refuses new ones).
core_handover_pending :: proc() -> bool {return handover.to != ""}

// The serve binary to hand over to, or why not. Temp.
core_handover_target :: proc(to: string) -> (path, why: string) {
	switch to {
	case CORE_CURRENT, CORE_PREVIOUS:
		p := core_serve_of(home_root, to)
		if p == "" do return "", fmt.tprintf("no %s core is installed", to)
		return p, ""
	case "self":
		when TEST_HOOKS {
			if autotest_active do return executable_path(), "" // test mode installs nothing
		}
	}
	return "", fmt.tprintf("unknown target %q (current or previous)", to)
}

core_handover_start :: proc(to: string) -> Result {
	if !core_separate do return fail("only a background core hands its sessions over")
	if handover.to != "" do return fail("a handover is already under way")
	path, why := core_handover_target(to)
	if why != "" do return fail(why)
	if !autotest_active {
		if w := holder_verify(path); w != "" do return fail(w)
	}
	c, ok, cwhy := core_check(path)
	if !ok do return fail(fmt.tprintf("the new background core failed its check: %s", cwhy))
	// the user's choice, kept until another build is made current: windows and the holder's
	// supervisor launch previous, and no window hands it back (client_core.odin)
	if to == CORE_PREVIOUS {
		if w := core_use_previous_set(home_root); w != "" do return fail(w)
	}
	handover.to = strings.clone(path)
	handover.formats = make([]string, len(c.snapshot))
	for f, i in c.snapshot do handover.formats[i] = strings.clone(f)
	handover.until = time.tick_add(time.tick_now(), jobs_handover_wait)
	n := jobs_running_count()
	fmt.eprintfln("Deckhand: background core: handing over to %s (%s, build %s)%s", path, c.version == "" ? "a development build" : c.version, c.build, n > 0 ? fmt.tprintf(" once %d job run(s) end, at most %v", n, jobs_handover_wait) : "")
	if autotest_active do fmt.printfln("[autotest] core handover: to %s, %d job run(s)", to, n)
	return {ok = true} // the next tick quits (this result reaches the window first)
}

jobs_handover_wait := JOBS_HANDOVER_WAIT // tests shorten it

// Every core tick: once no job run is left (or the wait is over), the core quits with the handover.
core_handover_tick :: proc() {
	if handover.to == "" || handover.quit do return
	if jobs_running_count() > 0 && time.tick_diff(time.tick_now(), handover.until) > 0 do return
	handover.quit = true
	// SIGTERM, never platform.quit: a core that quits on purpose tells its windows to quit too
	// (M4-D); one that stops by signal lets them reconnect, here to the successor
	posix.kill(posix.getpid(), .SIGTERM)
}

// The handover is due at quit (serve_stop): the successor gets the GOODBYE's secret.
core_handover_due :: proc() -> bool {return handover.quit}

// The snapshot formats the successor reads (SNAPSHOT_FORMATS when not a handover's quit).
core_handover_formats :: proc() -> []string {
	return handover.quit && len(handover.formats) > 0 ? handover.formats : SNAPSHOT_FORMATS[:]
}

// The last step (serve_stop, after everything else): locks released, the successor launched with
// the holder's secret. run: the runtime dir.
core_handover_finish :: proc(run: string) {
	if !handover.quit do return
	sync.lock(&hc.mu)
	secret := strings.clone(string(hc.successor[:hc.successor_len]), context.temp_allocator)
	trust_wipe(hc.successor[:])
	hc.successor_len = 0
	sync.unlock(&hc.mu)
	defer trust_wipe(transmute([]u8)secret)
	instance_lock_release(instance_core_fd)
	instance_lock_release(instance_fd)
	instance_core_fd, instance_fd = -1, -1
	if len(secret) != 64 do fmt.eprintln("Deckhand: background core: no successor secret (no held session, or no ack): the successor attaches as any core does")
	// a scene's older core hands over to the new one, which says its own version (remote-install.sh)
	when TEST_HOOKS do posix.unsetenv(strings.clone_to_cstring(HOOK_ENV[.Core_Version], context.temp_allocator))
	pid, ok, why := core_launch(handover.to, run, home_root, secret = len(secret) == 64 ? secret : "")
	if !ok {
		self := executable_path()
		fmt.eprintln("Deckhand: background core: the successor did not start:", why, "- starting this core's binary again,", self)
		pid, ok, why = core_launch(self, run, home_root, secret = len(secret) == 64 ? secret : "")
	}
	if !ok do fmt.eprintln("Deckhand: background core: no core started:", why, "- the next window launches one")
	else if autotest_active do fmt.printfln("[autotest] core handover: successor pid %d", pid)
}
