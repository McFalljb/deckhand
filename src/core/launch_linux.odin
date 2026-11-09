#+build linux
package core

// Starting a separate core on Linux (docs/plans/background-core.md §10.4 M6-L1). There is no
// launchd: the core is spawned directly in its own session (setsid; holder_launch_direct), its
// output in <run>/core.log, and is reparented once its launcher exits. M6-L2 starts it through
// systemd --user instead. The arguments are launchd_darwin.odin's core_launch's.

import "core:os"

core_launch :: proc(bin, run, data: string, from_tab := false, secret := "") -> (pid: i32, ok: bool, why: string) {
	ours, _ := os.environ(context.temp_allocator)
	return holder_launch_direct(bin, run, data, core_launch_env(ours, from_tab), "serve", secret)
}
