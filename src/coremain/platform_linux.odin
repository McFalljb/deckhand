#+build linux
package main

// deckhand-core-serve on Linux (docs/plans/background-core.md §10.4 M6-L1): no Obj-C shim. No
// banners of its own (with no window attached, the hub raises them: §8.6), no App Nap, and no
// Trash (platform.trash false: nothing is moved, fs_model.odin). platform_darwin.odin is the
// macOS side.

import "core:c"
import "core:fmt"

dh_core_activity :: proc(on: c.int) {}
dh_core_trash :: proc(path: cstring) -> c.int {return 0}
dh_core_notify :: proc(title, body: cstring) -> c.int {return 0}

// --ready is the launchd launcher's handshake (launchd_darwin.odin): never on Linux.
serve_ready_handshake :: proc(ready: string) -> bool {
	fmt.eprintln("deckhand-core serve: --ready is macOS's launchd handshake")
	return false
}
