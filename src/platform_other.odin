#+build !darwin
package main

import "core"
import "core:time"

// Stubs until Linux/Windows get their own versions (frames drain the inbox).

platform_wake :: proc() {}
platform_alert :: proc(title, text: string) {}
platform_hide_windows :: proc() {}
cpu_seconds :: proc() -> f64 {return 0}
window_raise_without_focus :: proc() {}
window_send_back :: proc() {}
window_set_content_size :: proc(w, h: f32) {}
window_minimize :: proc() {}
platform_test_scale :: proc(scale: f64) {}
platform_display_hook :: proc() {}
platform_display :: proc() -> (fps: int, scale: f32) {return 60, 1}
platform_display_link_fps :: proc() -> f32 {return 0}
platform_test_display_fps :: proc(fps: int) {}
platform_display_link_cap :: proc(cap: int) {}
window_restore :: proc() {}
app_deactivate :: proc() {}
app_hide :: proc() {}
app_unhide :: proc() {}
app_is_hidden :: proc() -> bool {return false}
window_capture :: proc(path: string) {}
platform_window_init :: proc() {}
platform_ime_cancel :: proc() {}
platform_system_light :: proc() -> bool {return false}
platform_watch_appearance :: proc() {}
platform_set_appearance :: proc(mode: core.Appearance) {}
test_window_light :: proc() -> bool {return false}
platform_ime_caret_moved :: proc() {}
window_drag :: proc() {}
window_titlebar_double_click :: proc() {}
platform_double_click_interval :: proc() -> f64 {return 0.5}
platform_pick_folder :: proc() -> string {return ""}
platform_open_url :: proc(url: string) -> bool {return false}
test_hit :: proc(x, y: f32) -> int {return 1}
test_light :: proc() -> (x, y: f32) {return}
test_ime :: proc(kind: int, text: string, key_code := 0, alt := false, repeat := false, ops := "", flags := 0) {}
platform_frame_drawn :: proc() {}
platform_left_button :: proc() -> bool {return true}
platform_clipboard_count :: proc() -> int {return 0}
platform_clipboard_set_secret :: proc(text: string) -> int {return 0}
platform_clipboard_clear_if :: proc(count: int) {}
platform_run_later :: proc(p: proc()) {
	client.busy += 1 // as the darwin trampoline
	defer client.busy -= 1
	p()
}
test_beeps :: proc() -> int {return 0}
test_panels :: proc() -> int {return 0}
test_has_input_context :: proc() -> bool {return true}
platform_menu_begin :: proc() {}
platform_menu_push :: proc(title: string) {}
platform_menu_pop :: proc() {}
platform_menu_separator :: proc() {}
platform_menu_item :: proc(title, key: string, mods: u64, tag, native: int, live: bool) {}
platform_menu_end :: proc() {}
test_menu_key :: proc(chars: string, mods: u64, key_code: int, key_window := true) -> bool {return false}
test_menu_dump :: proc() -> string {return ""}
platform_reveal :: proc(path: string) {}
platform_notify :: proc(title, body: string) {}
platform_quiet :: proc() {}

platform_activity :: proc(on: bool) {}
// no timer: frames tick the core
platform_core_timer :: proc(every: time.Duration, fire: proc()) {}
