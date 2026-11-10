#+build linux
package main

// deckhand-core-serve on Linux (docs/plans/background-core.md §10.4 M6-L1): no Obj-C shim. No
// banners of its own (with no window attached, the hub raises them: §8.6), no App Nap, and no
// Trash (platform.trash false: nothing is moved, fs_model.odin). platform_darwin.odin is the
// macOS side.

import "core:c"
import "core:fmt"

import "core:os"
import "core:path/filepath"

import "../core"

dh_core_activity :: proc(on: c.int) {}
dh_core_trash :: proc(path: cstring) -> c.int {return 0}
dh_core_notify :: proc(title, body: cstring) -> c.int {return 0}

// --ready is the launchd launcher's handshake (launchd_darwin.odin): never on Linux.
serve_ready_handshake :: proc(ready: string) -> bool {
	fmt.eprintln("deckhand-core serve: --ready is macOS's launchd handshake")
	return false
}

// `linger [--enable]` (§8.4, §10.4 M6-L2): prints on, off or unknown. --enable is the user's yes
// (M6-E's setup asks first): `loginctl enable-linger` with no password prompt; if polkit refuses,
// the command to run is shown and the exit is 1.
linger_main :: proc(args: []string) -> int {
	enable := len(args) == 1 && args[0] == "--enable"
	if len(args) > 1 || (len(args) == 1 && !enable) {
		fmt.eprintln("usage: deckhand-core-serve linger [--enable]")
		return 2
	}
	l := enable ? core.linger_enable() : core.linger_check()
	fmt.println(l == .On ? "on" : l == .Off ? "off" : "unknown")
	if enable && l != .On {
		fmt.eprintfln("deckhand-core-serve linger: still not on (polkit wants a password, or there is no logind); run it yourself: %s", core.LINGER_COMMAND)
		return 1
	}
	return 0
}

// The run dir the unit names (~/.local/state/deckhand/run) may not exist yet: made 0700 here, its
// parent too; then the linger the hello reports (not in test mode: scenes never ask logind).
serve_platform_prepare :: proc(run: string) -> bool {
	parent := filepath.dir(run)
	os.make_directory_all(parent, {.Read_User, .Write_User, .Execute_User})
	if why := core.runtime_dir_prepare(run, core.RUNTIME_CORE_NEED); why != "" {
		fmt.eprintln("deckhand-core serve:", why)
		return false
	}
	if !core.autotest_active do core.linger_state = core.linger_check()
	return true
}
