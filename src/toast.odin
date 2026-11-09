package main

// A short line at the bottom of the window for a few seconds: what a menu
// choice did when nothing else on screen shows it ("Session info copied"),
// or why it could not (menu_result, ui_sidebar.odin). One at a time: a new
// one replaces the last. Not saved, not in the bell.

import "core:fmt"
import "core:strings"
import "core:time"
import "core"
import clay "../build/clay-odin"

TOAST_TIME :: 3 * time.Second
TOAST_TIME_ERR :: 7 * time.Second // long enough to read why
TOAST_W_MAX :: 560 // logical px; longer text is cut

Toast :: struct {
	text:  string, // owned; "" = none
	err:   bool,
	until: time.Tick,
}
toast: Toast

toast_show :: proc(text: string, err := false) {
	delete(toast.text)
	toast = {text = strings.clone(core.one_line(text, context.temp_allocator)), err = err} // its time starts once the window shows (toast_tick)
	app.redraw = true
	if core.autotest_active do fmt.println("[autotest] toast:", err ? "error:" : "", toast.text)
}

toast_clear :: proc() {
	if toast.text != "" do app.redraw = true
	delete(toast.text)
	toast = {}
}

// The frame's tick: true when a shown toast just went away (draw a frame). A toast raised while the
// window is hidden or minimised (a separate core's, or a timer's) waits: its few seconds start
// when the window shows.
toast_tick :: proc() -> bool {
	if toast.text == "" do return false
	if toast.until == {} {
		if app_is_hidden() || window_minimised() do return false
		toast.until = time.tick_add(time.tick_now(), toast.err ? TOAST_TIME_ERR : TOAST_TIME)
		return false
	}
	if time.tick_diff(toast.until, time.tick_now()) < 0 do return false
	toast_clear()
	return true
}

// Bottom centre, above everything but the tooltip; clicks go through it.
toast_layout :: proc(w, h: f32) {
	if toast.text == "" do return
	th := theme()
	inner := min(px(TOAST_W_MAX), w - px(2 * SP_3 + 2 * SP_2))
	shown := clip(toast.text, inner)
	box_w := text_w(shown) + px(2 * SP_3)
	box_h := px(TIP_H + SP_2)
	if clay.UI(clay.ID("toast"))({
		layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFixed(box_h)}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(toast.err ? th.error : th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
		floating = {attachTo = .Root, offset = {max((w - box_w) / 2, 0), max(h - box_h - px(SP_3 * 2), 0)}, zIndex = 29, pointerCaptureMode = .Passthrough},
	}) {
		clay.TextDynamic(shown, txt(toast.err ? th.error : th.text))
	}
}
