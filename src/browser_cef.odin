package main

// Bindings for the CEF shim (src/native/cef_macos.m): flat C functions over
// CEF's C API. Built in only with -define:DECKHAND_CEF=true (build.sh, unless
// DECKHAND_NO_CEF=1); otherwise the stubs below say "not built in" and every
// browser tab shows that instead of a page. Unit tests build without CEF.

import "core:c"

DECKHAND_CEF :: #config(DECKHAND_CEF, false)

Cef_Callbacks :: struct {
	painted: proc "c" (id: c.int, w, h: c.int, accelerated: c.int, written: rawptr), // written: the ring slot's texture the frame went into
	ring:    proc "c" (tab_id: u64, w, h: c.int) -> c.int, // no ring fits a w x h px paint: make one now (1 = made; 0: later, then dh_cef_invalidate)
	title:   proc "c" (id: c.int, utf8: cstring),
	loading: proc "c" (id: c.int, loading: c.int),
	closed:  proc "c" (id: c.int),
	log:     proc "c" (utf8: cstring),
	// step 2 (navigation, browser_nav.odin)
	address: proc "c" (id: c.int, utf8: cstring), // the main frame's URL
	nav:     proc "c" (id: c.int, loading, can_back, can_forward: c.int),
	popup:   proc "c" (opener, slot: c.int, url: cstring, user_gesture, background: c.int) -> u64, // a tab for the popup (0 = refused)
}

// A CDP message from browser id: a method's result (msg_id > 0, method nil; ok: its "result",
// else its "error") or an event (msg_id 0: method, its "params"). json is len bytes, valid
// only during the call.
Cef_Devtools_Fn :: #type proc "c" (id: c.int, msg_id: c.int, ok: c.int, method: cstring, json: [^]u8, len: c.size_t)
// dh_cef_history
CEF_BACK :: 0
CEF_FORWARD :: 1
CEF_RELOAD :: 2
CEF_STOP :: 3

// cef_key_event_type_t
CEF_KEY_RAWKEYDOWN :: 0
CEF_KEY_UP :: 2
CEF_KEY_CHAR :: 3
// cef_event_flags_t
CEF_FLAG_SHIFT :: 1 << 1
CEF_FLAG_CONTROL :: 1 << 2
CEF_FLAG_ALT :: 1 << 3
CEF_FLAG_LEFT_BUTTON :: 1 << 4
CEF_FLAG_COMMAND :: 1 << 7

when DECKHAND_CEF && ODIN_OS == .Darwin {
	foreign import pdcef {
		"../build/dh_cef.a",
		"system:Metal.framework",
		"system:IOSurface.framework",
		"system:Cocoa.framework",
	}

	@(default_calling_convention = "c")
	foreign pdcef {
		dh_cef_start :: proc(mtl_device: rawptr, root_cache, log_file: cstring, shared: c.int, no_network: c.int, cbs: ^Cef_Callbacks) -> c.int ---
		dh_cef_running :: proc() -> c.int ---
		dh_cef_pump_due :: proc() ---
		dh_cef_open :: proc(url: cstring, w, h: c.int, scale: f32, tab_id: u64) -> c.int ---
		dh_cef_resize :: proc(id: c.int, w, h: c.int, scale: f32) ---
		dh_cef_set_hidden :: proc(id: c.int, hidden: c.int) ---
		dh_cef_focus :: proc(id: c.int, focused: c.int) ---
		dh_cef_invalidate :: proc(id: c.int) ---
		dh_cef_mouse_move :: proc(id: c.int, x, y, mods: c.int, leave: c.int) ---
		dh_cef_mouse_click :: proc(id: c.int, x, y, mods, button, up, count: c.int) ---
		dh_cef_wheel :: proc(id: c.int, x, y, mods, dx, dy: c.int) ---
		dh_cef_key :: proc(id: c.int, type, native, mods: c.int, ch, unmod: u16) ---
		dh_cef_exec_js :: proc(id: c.int, js: cstring) ---
		dh_cef_ready :: proc(id: c.int) -> c.int ---
		dh_cef_free_slots :: proc(closing: c.int) -> c.int ---
		dh_cef_navigate :: proc(id: c.int, url: cstring) ---
		dh_cef_history :: proc(id: c.int, what: c.int) ---
		dh_cef_test_scheme :: proc(root: cstring) -> c.int ---
		dh_cef_stats :: proc(id: c.int, gpu, cpu: ^u64, first_paint_ms: ^f64, pumps: ^u64, dropped: ^u64) ---
		dh_cef_close :: proc(id: c.int) ---
		dh_cef_shutdown :: proc() ---
		// the DevTools protocol in process (browser_annotate.odin)
		dh_cef_devtools_callback :: proc(fn: Cef_Devtools_Fn) ---
		dh_cef_devtools_send :: proc(id: c.int, json: [^]u8, len: c.size_t) -> c.int ---
	}
	CEF_BUILT_IN :: true
} else {
	CEF_BUILT_IN :: false
	dh_cef_start :: proc(mtl_device: rawptr, root_cache, log_file: cstring, shared: c.int, no_network: c.int, cbs: ^Cef_Callbacks) -> c.int {return 0}
	dh_cef_running :: proc() -> c.int {return 0}
	dh_cef_pump_due :: proc() {}
	dh_cef_open :: proc(url: cstring, w, h: c.int, scale: f32, tab_id: u64) -> c.int {return 0}
	dh_cef_resize :: proc(id: c.int, w, h: c.int, scale: f32) {}
	dh_cef_set_hidden :: proc(id: c.int, hidden: c.int) {}
	dh_cef_focus :: proc(id: c.int, focused: c.int) {}
	dh_cef_invalidate :: proc(id: c.int) {}
	dh_cef_mouse_move :: proc(id: c.int, x, y, mods: c.int, leave: c.int) {}
	dh_cef_mouse_click :: proc(id: c.int, x, y, mods, button, up, count: c.int) {}
	dh_cef_wheel :: proc(id: c.int, x, y, mods, dx, dy: c.int) {}
	dh_cef_key :: proc(id: c.int, type, native, mods: c.int, ch, unmod: u16) {}
	dh_cef_exec_js :: proc(id: c.int, js: cstring) {}
	dh_cef_ready :: proc(id: c.int) -> c.int {return 0}
	dh_cef_free_slots :: proc(closing: c.int) -> c.int {return 8}
	dh_cef_navigate :: proc(id: c.int, url: cstring) {}
	dh_cef_history :: proc(id: c.int, what: c.int) {}
	dh_cef_test_scheme :: proc(root: cstring) -> c.int {return 0}
	dh_cef_stats :: proc(id: c.int, gpu, cpu: ^u64, first_paint_ms: ^f64, pumps: ^u64, dropped: ^u64) {}
	dh_cef_close :: proc(id: c.int) {}
	dh_cef_shutdown :: proc() {}
	dh_cef_devtools_callback :: proc(fn: Cef_Devtools_Fn) {}
	dh_cef_devtools_send :: proc(id: c.int, json: [^]u8, len: c.size_t) -> c.int {return 0}
}
