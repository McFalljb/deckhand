package main

// The palette's *Restart session holder* (development builds only, docs/GUIDE.md): the attached
// session holder upgrades in place to this build's holder binary (holder_upgrade, §7.3), so a
// rebuilt holder takes effect without ending any session. The upgrade runs on its own thread
// (it can take seconds); its outcome is a toast on the next frame (holder_restart_tick).

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
holder_restart_text :: proc(r: Holder_Upgrade_Result) -> (msg: string, err: bool) {
	switch {
	case r.ok:
		return fmt.aprintf("Session holder restarted (holder_rev %d): every session kept", r.holder_rev), false
	case r.adopted:
		return fmt.aprintf("Session holder: the new binary did not take over (%s). Sessions run on, degraded", r.error), true
	case r.lost:
		return fmt.aprintf("Session holder lost: %s", r.error), true
	case r.timed_out:
		return strings.clone("Session holder: the restart is still going after a long wait; sessions keep running. Check again in a moment"), true
	}
	return fmt.aprintf("Session holder not restarted: %s. Sessions run on as before", r.error), true
}

holder_restart_start :: proc() {
	sync.lock(&restart.mu)
	if restart.running {
		sync.unlock(&restart.mu)
		toast_show("The session holder is already restarting")
		return
	}
	restart.running = true
	sync.unlock(&restart.mu)
	thread.run(proc() {
		msg: string
		err := true
		bin := holder_bin_find(context.temp_allocator)
		path, ok, why := holder_install(bin, home_root)
		if bin == "" || !ok {
			msg = fmt.aprintf("Session holder not restarted: %s", bin == "" ? "deckhand-core not found" : why)
		} else {
			r := holder_upgrade(path)
			msg, err = holder_restart_text(r)
			delete(r.error)
			delete(path)
		}
		sync.lock(&restart.mu)
		delete(restart.msg)
		restart.msg, restart.err, restart.running = msg, err, false
		sync.unlock(&restart.mu)
	})
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
