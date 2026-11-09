#+build darwin
package main

// deckhand-core-serve's macOS calls: the Obj-C shim (core_macos.m: App Nap, the Trash, Deckhand
// Core's own banners) and the launchd launcher's ready handshake (src/holder detach.odin).
// platform_linux.odin is the Linux side.

import "core:c"

import "../core"
import "../holder"

foreign import shim {
	"../../build/dh_coremain.a",
	"system:UserNotifications.framework",
}
foreign import foundation "system:Foundation.framework"
@(default_calling_convention = "c")
foreign shim {
	dh_core_activity :: proc(on: c.int) ---
	dh_core_trash :: proc(path: cstring) -> c.int ---
	dh_core_notify :: proc(title, body: cstring) -> c.int ---
}
_ :: foundation

// launched through launchd: the launcher's environment (it carries the window's settings), and a
// handover's successor secret (core.successor_given)
serve_ready_handshake :: proc(ready: string) -> bool {
	_, ok := holder.ready_handshake(ready, &core.successor_given)
	return ok
}
