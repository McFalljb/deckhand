#+build darwin
package main

// macOS pieces behind the platform split: the main-thread wake (GCD) and the
// window/process hooks the test mode needs.

import "base:intrinsics"
import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import NS "core:sys/darwin/Foundation"
import sapp "../vendor/sokol-odin/sokol/app"

foreign import libsystem "system:System"

@(default_calling_convention = "c")
foreign libsystem {
	@(link_name = "_dispatch_main_q")
	dispatch_main_q: u8 // the main queue object; dispatch_get_main_queue() is &_dispatch_main_q
	dispatch_async_f :: proc(queue: rawptr, ctx: rawptr, work: proc "c" (ctx: rawptr)) ---
	system :: proc(cmd: cstring) -> c.int ---
	getrusage :: proc(who: c.int, usage: ^Rusage) -> c.int ---
}

Timeval :: struct {
	sec:  i64,
	usec: i32,
}
Rusage :: struct {
	utime, stime: Timeval,
	_:            [14]i64,
}

@(private = "file")
wake_pending: bool

// Runs inbox_drain on the main thread's run loop. This works while sokol's
// frame callback is slowed or stopped (window hidden, App Nap). Coalesced:
// at most one wake is queued at a time.
platform_wake :: proc() {
	if _, swapped := sync.atomic_compare_exchange_strong(&wake_pending, false, true); !swapped do return
	dispatch_async_f(&dispatch_main_q, nil, on_wake)
}

@(private = "file")
on_wake :: proc "c" (ctx: rawptr) {
	context = app_context
	defer free_all(context.temp_allocator)
	sync.atomic_store(&wake_pending, false)
	app.wakes += 1
	if app.ready do inbox_drain()
}

// Runs p from the main queue: outside sokol's event and frame callbacks
// (for modal loops such as the folder picker).
platform_run_later :: proc(p: proc()) {
	dispatch_async_f(&dispatch_main_q, rawptr(p), proc "c" (ctx: rawptr) {
		context = app_context
		defer free_all(context.temp_allocator)
		(proc())(ctx)()
	})
}

cpu_seconds :: proc() -> f64 {
	ru: Rusage
	getrusage(0, &ru)
	return f64(ru.utime.sec + ru.stime.sec) + f64(ru.utime.usec + ru.stime.usec) / 1e6
}

@(private = "file")
window :: proc() -> ^NS.Window {return (^NS.Window)(sapp.macos_get_window())}

// Brings the window forward without taking keyboard focus.
window_raise_without_focus :: proc() {intrinsics.objc_send(nil, window(), "orderFrontRegardless")}
window_send_back :: proc() {intrinsics.objc_send(nil, window(), "orderBack:", rawptr(nil))}
window_set_content_size :: proc(w, h: f32) {
	intrinsics.objc_send(nil, window(), "setContentSize:", NS.Size{NS.Float(w), NS.Float(h)})
}
window_minimize :: proc() {intrinsics.objc_send(nil, window(), "miniaturize:", rawptr(nil))}
window_restore :: proc() {intrinsics.objc_send(nil, window(), "deminiaturize:", rawptr(nil))}
app_deactivate :: proc() {intrinsics.objc_send(nil, NS.Application_sharedApplication(), "deactivate")}

// Captures only this window into path (PNG).
window_capture :: proc(path: string) {
	wid := intrinsics.objc_send(NS.Integer, window(), "windowNumber")
	system(fmt.ctprintf("screencapture -x -o -l%d %s", wid, path))
}

// ---- window pieces sokol lacks (src/native/platform_macos.m) ----

foreign import pdplatform {
	"../build/dh_platform.a",
	"system:Cocoa.framework",
	"system:UserNotifications.framework",
}

@(private = "file")
Ime_Callbacks :: struct {
	insert:          proc "c" (utf8: [^]u8, n: c.int),
	marked:          proc "c" (utf8: [^]u8, n: c.int, caret: c.int),
	caret_rect:      proc "c" (x, y, w, h: ^f32),
	option_composes: proc "c" () -> c.int,
}

@(default_calling_convention = "c")
foreign pdplatform {
	dh_mac_init :: proc(window: rawptr, cb: ^Ime_Callbacks, bar_h, light_x, min_w, min_h: f32) ---
	dh_mac_ime_cancel :: proc() ---
	dh_mac_place_lights :: proc() ---
	dh_mac_ime_caret_moved :: proc() ---
	dh_mac_window_drag :: proc() ---
	dh_mac_titlebar_double_click :: proc() ---
	dh_mac_double_click_interval :: proc() -> f64 ---
	dh_mac_pick_folder :: proc(buf: [^]u8, cap: c.int) -> c.int ---
	dh_mac_reveal :: proc(path: cstring) ---
	dh_mac_open_url :: proc(url: cstring) -> c.int ---
	dh_mac_test_hit :: proc(x, y: f32) -> c.int ---
	dh_mac_test_light :: proc(x, y: ^f32) ---
	dh_mac_test_beeps :: proc() -> c.int ---
	dh_mac_test_panels :: proc() -> c.int ---
	dh_mac_test_has_input_context :: proc() -> c.int ---
	dh_mac_system_light :: proc() -> c.int ---
	dh_mac_watch_appearance :: proc(changed: proc "c" (light: c.int)) ---
	dh_mac_set_appearance :: proc(mode: c.int) ---
	dh_mac_test_window_light :: proc() -> c.int ---
	dh_mac_test_ime :: proc(kind: c.int, text: cstring, key_code: c.int, alt: c.int, ops: cstring) ---
	dh_mac_notify :: proc(title, body: cstring) ---
	dh_mac_quiet :: proc() ---
	dh_mac_alert :: proc(title, text: cstring) ---
	dh_mac_hide_windows :: proc() ---
	dh_mac_test_scale :: proc(scale: f64) ---
	dh_mac_left_button_down :: proc() -> c.int ---
	dh_mac_pasteboard_count :: proc() -> c.long ---
	dh_mac_pasteboard_set_secret :: proc(text: cstring) -> c.long ---
	dh_mac_pasteboard_clear_if :: proc(count: c.long) ---
	dh_mac_activity :: proc(on: c.int) ---
	dh_mac_display_hook :: proc() ---
	dh_mac_display_fps :: proc() -> c.int ---
	dh_mac_display_scale :: proc() -> f32 ---
	dh_mac_display_link_fps :: proc() -> f32 ---
	dh_mac_test_display_fps :: proc(fps: c.int) ---
	dh_mac_display_link_cap :: proc(cap: c.int) ---
}

// The display link's rate: at most cap frames per second (0 = the screen's maximum). Cheap when
// unchanged (each frame; main.odin).
platform_display_link_cap :: proc(cap: int) {dh_mac_display_link_cap(c.int(cap))}

// Before sokol starts: its display link follows the window's screen's rate, not the main
// screen's (src/native/platform_macos.m).
platform_display_hook :: proc() {dh_mac_display_hook()}
// The window's screen: its maximum frames per second and backing scale (any thread; app tabs
// pace from them: docs/ENGINE-BRIDGE.md §2.1).
platform_display :: proc() -> (fps: int, scale: f32) {return int(dh_mac_display_fps()), dh_mac_display_scale()}
// The rate sokol's display link asks for now (tests; 0 = none).
platform_display_link_fps :: proc() -> f32 {return dh_mac_display_link_fps()}
// Test mode: report this rate as the screen's (0 = the real one).
platform_test_display_fps :: proc(fps: int) {dh_mac_test_display_fps(c.int(fps))}

// While a job runs: no App Nap (timers on time; the system may still sleep).
platform_activity :: proc(on: bool) {dh_mac_activity(on ? 1 : 0)}

// Quiet test mode, before sokol starts: never activates, window off-screen
// (src/native/platform_macos.m).
platform_quiet :: proc() {dh_mac_quiet()}
// A modal alert with one Quit button (before the window is of use: instance.odin)
platform_hide_windows :: proc() {dh_mac_hide_windows()}
platform_alert :: proc(title, text: string) {dh_mac_alert(strings.clone_to_cstring(title, context.temp_allocator), strings.clone_to_cstring(text, context.temp_allocator))}

// Test mode, before sokol starts: every screen and window reports this backing scale
// (DECKHAND_SCALE; src/native/platform_macos.m).
platform_test_scale :: proc(scale: f64) {dh_mac_test_scale(scale)}

platform_notify :: proc(title, body: string) {
	dh_mac_notify(strings.clone_to_cstring(title, context.temp_allocator), strings.clone_to_cstring(body, context.temp_allocator))
}

// Blended title bar and input methods; call once the window exists.
platform_window_init :: proc() {
	@(static) cb := Ime_Callbacks {
		insert = proc "c" (utf8: [^]u8, n: c.int) {
			context = app_context
			ime_commit(string(utf8[:n]))
		},
		marked = proc "c" (utf8: [^]u8, n: c.int, caret: c.int) {
			context = app_context
			ime_set_marked(string(utf8[:n]), int(caret))
		},
		caret_rect = proc "c" (x, y, w, h: ^f32) {
			context = app_context
			r := ime_anchor()
			x^, y^, w^, h^ = r[0], r[1], r[2], r[3]
		},
		option_composes = proc "c" () -> c.int {
			context = app_context
			return ime_option_composes() ? 1 : 0
		},
	}
	dh_mac_init(sapp.macos_get_window(), &cb, TAB_STRIP_H, LIGHTS_X, WINDOW_MIN_W, WINDOW_MIN_H)
}

platform_ime_cancel :: proc() {dh_mac_ime_cancel()}

// The OS appearance now; changes arrive as System_Appearance commands
// (KVO on the main thread, through the inbox).
platform_system_light :: proc() -> bool {return dh_mac_system_light() != 0}
platform_watch_appearance :: proc() {
	dh_mac_watch_appearance(proc "c" (light: c.int) {
		context = app_context
		on_system_appearance(light != 0)
	})
}
platform_set_appearance :: proc(mode: Appearance) {
	dh_mac_set_appearance(c.int(mode == .Light ? 1 : mode == .Dark ? 2 : 0))
}
test_window_light :: proc() -> bool {return dh_mac_test_window_light() != 0}
platform_frame_drawn :: proc() {dh_mac_place_lights()}

// The left mouse button as the OS sees it now (not from our events).
platform_left_button :: proc() -> bool {return dh_mac_left_button_down() != 0}
platform_clipboard_count :: proc() -> int {return int(dh_mac_pasteboard_count())}
platform_clipboard_set_secret :: proc(text: string) -> int {return int(dh_mac_pasteboard_set_secret(strings.clone_to_cstring(text, context.temp_allocator)))}
platform_clipboard_clear_if :: proc(count: int) {dh_mac_pasteboard_clear_if(c.long(count))}
platform_ime_caret_moved :: proc() {dh_mac_ime_caret_moved()}
window_drag :: proc() {dh_mac_window_drag()}
window_titlebar_double_click :: proc() {dh_mac_titlebar_double_click()}
platform_double_click_interval :: proc() -> f64 {return dh_mac_double_click_interval()}

platform_pick_folder :: proc() -> string {
	buf: [4096]u8
	n := dh_mac_pick_folder(&buf[0], len(buf))
	return n > 0 ? strings.clone(string(buf[:n]), context.temp_allocator) : ""
}

platform_reveal :: proc(path: string) {dh_mac_reveal(strings.clone_to_cstring(path, context.temp_allocator))}
platform_open_url :: proc(url: string) -> bool {return dh_mac_open_url(strings.clone_to_cstring(url, context.temp_allocator)) == 1}

// Test mode: what a click at (x, y) framebuffer px reaches (1 our view, 0
// the title bar, -1 nothing), the close button's centre, input method calls.
test_hit :: proc(x, y: f32) -> int {return int(dh_mac_test_hit(x, y))}
test_light :: proc() -> (x, y: f32) {
	dh_mac_test_light(&x, &y)
	return
}
test_ime :: proc(kind: int, text: string, key_code := 0, alt := false, repeat := false, ops := "", flags := 0) {
	f := c.int(flags) | (alt ? 1 : 0) | (repeat ? 2 : 0)
	dh_mac_test_ime(c.int(kind), strings.clone_to_cstring(text, context.temp_allocator), c.int(key_code), f, strings.clone_to_cstring(ops, context.temp_allocator))
}
test_beeps :: proc() -> int {return int(dh_mac_test_beeps())}
test_panels :: proc() -> int {return int(dh_mac_test_panels())}
test_has_input_context :: proc() -> bool {return dh_mac_test_has_input_context() != 0}

// ---- the menu bar (src/native/menubar_macos.m; built by menubar.odin) ----

@(private = "file")
Menu_Callbacks :: struct {
	fire:  proc "c" (tag: c.int),
	state: proc "c" (tag: c.int) -> c.int,
	title: proc "c" (tag: c.int, buf: [^]u8, cap: c.int) -> c.int,
}

@(default_calling_convention = "c")
foreign pdplatform {
	dh_mac_menu_begin :: proc(window: rawptr, cb: ^Menu_Callbacks) ---
	dh_mac_menu_push :: proc(title: cstring) ---
	dh_mac_menu_pop :: proc() ---
	dh_mac_menu_separator :: proc() ---
	dh_mac_menu_item :: proc(title, key: cstring, mods: c.ulong, tag, native, live: c.int) ---
	dh_mac_menu_end :: proc() ---
	dh_mac_test_menu_key :: proc(chars: cstring, mods: c.ulong, key_code, key_window: c.int) -> c.int ---
	dh_mac_menu_dump :: proc(buf: [^]u8, cap: c.int) -> c.int ---
}

platform_menu_begin :: proc() {
	@(static) cb := Menu_Callbacks {
		fire = proc "c" (tag: c.int) {
			context = app_context
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD() // AppKit may call in while Odin code runs (tests: dump, keys)
			menubar_fire(int(tag))
		},
		state = proc "c" (tag: c.int) -> c.int {
			context = app_context
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD() // AppKit may call in while Odin code runs (tests: dump, keys)
			enabled, checked := menubar_state(int(tag))
			return c.int((enabled ? 1 : 0) | (checked ? 2 : 0))
		},
		title = proc "c" (tag: c.int, buf: [^]u8, cap: c.int) -> c.int {
			context = app_context
			runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD() // AppKit may call in while Odin code runs (tests: dump, keys)
			t := menubar_title(int(tag))
			if len(t) >= int(cap) do return 0
			copy(buf[:cap], t)
			return c.int(len(t))
		},
	}
	dh_mac_menu_begin(sapp.macos_get_window(), &cb)
}
platform_menu_push :: proc(title: string) {dh_mac_menu_push(strings.clone_to_cstring(title, context.temp_allocator))}
platform_menu_pop :: proc() {dh_mac_menu_pop()}
platform_menu_separator :: proc() {dh_mac_menu_separator()}
platform_menu_item :: proc(title, key: string, mods: u64, tag, native: int, live: bool) {
	dh_mac_menu_item(strings.clone_to_cstring(title, context.temp_allocator), strings.clone_to_cstring(key, context.temp_allocator), c.ulong(mods), c.int(tag), c.int(native), live ? 1 : 0)
}
platform_menu_end :: proc() {dh_mac_menu_end()}

// Test mode: a key press through the menu bar's key equivalents, else the
// view (true: the menu bar took it); key_window false: as if another
// window (the About panel) had the keyboard. chars: the key's characters; mods:
// NSEventModifierFlags; key_code: the Mac virtual key code.
test_menu_key :: proc(chars: string, mods: u64, key_code: int, key_window := true) -> bool {
	return dh_mac_test_menu_key(strings.clone_to_cstring(chars, context.temp_allocator), c.ulong(mods), c.int(key_code), key_window ? 1 : 0) != 0
}

// Test mode: the menu bar as text, validated now (temp allocator).
test_menu_dump :: proc() -> string {
	buf := make([]u8, 1 << 16, context.temp_allocator)
	n := dh_mac_menu_dump(&buf[0], c.int(len(buf)))
	return string(buf[:n])
}
