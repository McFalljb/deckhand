package main

// The palette's *Restart session holder* (development builds only, docs/GUIDE.md): the attached
// session holder upgrades in place to this build's holder binary (holder_upgrade, §7.3), so a
// rebuilt holder takes effect without ending any session. The upgrade runs on its own thread
// (it can take seconds); its outcome is a toast on the next frame (holder_restart_tick).
//
// The same upgrade runs by itself once per run (holder_upgrade_tick) when the attached holder is
// older than the one this app bundles (holder_upgrade_wanted): after an update (the new app,
// attached as the named successor, holder_successor.odin), or a new Deckhand put in place by
// hand while a holder kept sessions. It waits for the launch's adopt; it says nothing when it
// works, and a toast when it does not (the sessions run on, on the old holder or degraded).

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"

@(private = "file")
restart: struct {
	mu:      sync.Mutex,
	running: bool,
	msg:     string, // the outcome, until shown (heap)
	err:     bool,
	auto:    bool, // holder_upgrade_tick started one this run (never again: no retry loop)
	unavailable_told: bool, // holder_upgrade_unavailable was said (once per run)
}

// Offered when a holder is attached and the bundled holder is a development build (under build/).
holder_restart_available :: proc() -> bool {
	if !hc.on || hc.lost || hc.handed do return false
	bin := holder_bin_find(context.temp_allocator)
	return bin != "" && holder_bin_dev_build(bin)
}

// A holder binary built from source: under a build/ dir whose parent has build.sh. Only gates the
// palette's Restart; holder_install copies a development build like a release.
holder_bin_dev_build :: proc(bin: string) -> bool {
	d := filepath.dir(bin)
	for d != "/" && d != "." && d != "" {
		if filepath.base(d) == "build" && os.is_file(fmt.tprintf("%s/../build.sh", d)) do return true
		d = filepath.dir(d)
	}
	return false
}

// What Restart says about an outcome (heap). err: shown as an error.
// auto: holder_upgrade_tick's upgrade (an older holder at attach), else the palette's Restart.
holder_restart_text :: proc(r: Holder_Upgrade_Result, auto := false) -> (msg: string, err: bool) {
	switch {
	case r.ok:
		return fmt.aprintf("Session holder %s (holder_rev %d): every session kept", auto ? "upgraded" : "restarted", r.holder_rev), false
	case r.adopted:
		return fmt.aprintf("Session holder: the new binary did not take over (%s). Sessions run on, degraded", r.error), true
	case r.lost:
		return fmt.aprintf("Session holder lost: %s", r.error), true
	case r.timed_out:
		return fmt.aprintf("Session holder: the %s is still going after a long wait; sessions keep running. Check again in a moment", auto ? "upgrade" : "restart"), true
	}
	return fmt.aprintf("Session holder not %s: %s. Sessions run on as before", auto ? "upgraded" : "restarted", r.error), true
}

holder_restart_start :: proc() {
	if !holder_upgrade_run(false) do toast_show("The session holder is already restarting")
}

// Whether the automatic upgrade is due now (pure: holder_client_test.odin): once per run, after
// the launch's adopt, while the attached holder is older than the bundled one and no upgrade runs.
holder_upgrade_due :: proc(tried, adopt_done, wanted, running: bool) -> bool {
	return !tried && adopt_done && wanted && !running
}

// Main thread, every frame (cheap until a holder is attached): starts the automatic upgrade.
holder_upgrade_tick :: proc() {
	if !hc.on || !hc.adopt_done do return
	if !restart.unavailable_told {
		// an older holder that can't be upgraded in place (rev 1, or a keeper): said once, plain info
		restart.unavailable_told = true
		if why := holder_upgrade_unavailable(); why != "" do toast_show(why)
	}
	if restart.auto do return
	sync.lock(&restart.mu)
	running := restart.running
	sync.unlock(&restart.mu)
	if !holder_upgrade_due(restart.auto, hc.adopt_done, holder_upgrade_wanted(), running) do return
	restart.auto = true
	holder_upgrade_run(true)
}

// The upgrade on its own thread; false when one already runs. auto: holder_upgrade_tick's (quiet
// when it works; its toasts say what happened to the sessions).
@(private = "file")
holder_upgrade_run :: proc(auto: bool) -> bool {
	sync.lock(&restart.mu)
	if restart.running {
		sync.unlock(&restart.mu)
		return false
	}
	restart.running = true
	sync.unlock(&restart.mu)
	worker :: proc(auto: bool) {
		msg: string
		err := true
		bin := holder_bin_find(context.temp_allocator)
		path, ok, why := holder_install(bin, home_root)
		what := auto ? "Session holder not upgraded" : "Session holder not restarted"
		if bin == "" || !ok {
			msg = fmt.aprintf("%s: %s", what, bin == "" ? "deckhand-core not found" : why)
		} else {
			r := holder_upgrade(path)
			if auto && r.ok {
				fmt.eprintfln("Deckhand: session holder: upgraded in place to holder_rev %d, every session kept", r.holder_rev)
				err = false
			} else do msg, err = holder_restart_text(r, auto)
			delete(r.error)
			delete(path)
		}
		if auto && msg != "" do fmt.eprintln("Deckhand:", msg)
		sync.lock(&restart.mu)
		delete(restart.msg)
		restart.msg, restart.err, restart.running = msg, err, false
		sync.unlock(&restart.mu)
	}
	thread.run_with_poly_data(auto, worker)
	return true
}

// Main thread, every frame: shows an outcome once. True when it showed one (redraw).
holder_restart_tick :: proc() -> bool {
	if !sync.try_lock(&restart.mu) do return false
	defer sync.unlock(&restart.mu)
	if restart.msg == "" do return false
	toast_show(restart.msg, err = restart.err)
	delete(restart.msg)
	restart.msg = ""
	return true
}
