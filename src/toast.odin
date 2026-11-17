package main

// A short line at the bottom of the window for a few seconds: what a menu
// choice did when nothing else on screen shows it ("Session info copied"),
// or why it could not (menu_result, ui_sidebar.odin; an error's reason wraps
// to two lines and stays longer). One at a time: a new
// one replaces the last. Not saved, not in the bell. A toast may carry one action (the Files
// tree's Undo: toast_show_action), a button at its end that a click runs; the press and its
// release reach nothing under it.

import "core:fmt"
import "core:strings"
import "core:time"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

TOAST_TIME :: 3 * time.Second
TOAST_TIME_ERR :: 7 * time.Second // long enough to read why
TOAST_W_MAX :: 560 // logical px; longer text is cut (an error's wraps first)
TOAST_ERR_LINES :: 2
TOAST_TIME_ACTION :: 6 * time.Second // long enough to reach its button

Toast :: struct {
	text:  string, // owned; "" = none
	err:   bool,
	until: time.Tick,
	action: string, // the button's label ("" = none; a constant)
	on_action: proc(arg: u64),
	arg:   u64,
}
toast: Toast

// A press on a toast's button: its release is the button's too.
@(private = "file")
toast_pressed: bool

// A toast with a button (label) that runs on_action(arg) when clicked; it then goes.
toast_show_action :: proc(text, label: string, on_action: proc(arg: u64), arg: u64) {
	toast_show(text)
	toast.action, toast.on_action, toast.arg = label, on_action, arg
}

// A click on the toast's button (event(), before anything under it). True: taken.
toast_event :: proc(e: ^sapp.Event) -> bool {
	#partial switch e.type {
	case .MOUSE_DOWN:
		if toast.text == "" || toast.action == "" || toast.on_action == nil || e.mouse_button != .LEFT do return false
		if !inside(clay.ID("toast_action"), e.mouse_x, e.mouse_y) do return false
		run, arg := toast.on_action, toast.arg
		toast_clear()
		toast_pressed = true
		run(arg)
		return true
	case .MOUSE_UP:
		if !toast_pressed do return false
		toast_pressed = false
		return true
	}
	return false
}
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
		toast.until = time.tick_add(time.tick_now(), toast.err ? TOAST_TIME_ERR : (toast.action != "" ? TOAST_TIME_ACTION : TOAST_TIME))
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
	action_w := toast.action != "" ? text_w(toast.action) + px(2 * SP_2) : 0
	if action_w > 0 do inner = max(inner - action_w - px(SP_3), 0)
	shown := clip(toast.text, inner)
	box_h := px(TIP_H + SP_2)
	if toast.err { // why something failed: up to TOAST_ERR_LINES lines, so the reason reads whole
		lines: int
		shown, lines = wrap_clip(toast.text, inner, TOAST_ERR_LINES)
		box_h += f32(max(lines, 1) - 1) * text_line_height(.UI)
	}
	box_w: f32 = 0
	for l in strings.split_lines(shown, context.temp_allocator) do box_w = max(box_w, text_w(l))
	box_w += px(2 * SP_3)
	if action_w > 0 do box_w += action_w + px(SP_3)
	cfg := txt(toast.err ? th.error : th.text)
	cfg.wrapMode = .Newlines
	if clay.UI(clay.ID("toast"))({
		layout = {sizing = {clay.SizingFixed(box_w), clay.SizingFixed(box_h)}, padding = {pu(SP_3), pu(action_w > 0 ? SP_1 : SP_3), 0, 0}, childGap = pu(SP_3), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
		border = {color = cc(toast.err ? th.error : th.border), width = clay.BorderOutside(pu(core.BORDER_W))},
		floating = {attachTo = .Root, offset = {max((w - box_w) / 2, 0), max(h - box_h - px(SP_3 * 2), 0)}, zIndex = 29, pointerCaptureMode = .Passthrough},
	}) {
		clay.TextDynamic(shown, cfg)
		if action_w > 0 {
			id := clay.ID("toast_action")
			bg, em := overlay(id, false, inside(id, app.pointer.x, app.pointer.y))
			if clay.UI(id)({
				layout = {sizing = {clay.SizingFixed(action_w), clay.SizingFixed(px(TIP_H))}, childAlignment = {x = .Center, y = .Center}},
				backgroundColor = bg,
				cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			}) {
				clay.TextDynamic(toast.action, txt(mix(th.accent, th.text, em)))
			}
		}
	}
}
