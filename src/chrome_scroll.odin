package main

// The wheel over the chrome's Clay lists (the left column's Sessions and Files, the right column,
// popovers, sheets, the Deck, Settings): one Clay scroll update per layout.
//
// Clay_UpdateScrollContainers marks every scroll container "not open this frame" and drops the
// ones already so marked: a second call before the next layout drops them all, and the next layout
// starts each list again at the top. A trackpad sends several precise deltas per frame (and its
// momentum after the fingers lift), so the list went down, back to the top, down again: it
// flickered while scrolling down (going up it only ended at the top early). The deltas between two
// layouts are summed here and applied once, at the pointer of the first of them, just before the
// next layout.

import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
pending: struct {
	at:    [2]f32,
	delta: [2]f32,
	any:   bool,
}

// A wheel event at `at` (window px) over a Clay list: applied at the next layout.
chrome_scroll :: proc(at: [2]f32, delta: [2]f32) {
	if !pending.any do pending.at = at
	pending.delta += delta
	pending.any = true
}

// The wheel event's own place and deltas.
chrome_scroll_event :: proc(e: ^sapp.Event) {
	chrome_scroll({e.mouse_x, e.mouse_y}, {e.scroll_x, e.scroll_y})
}

// Before a layout (ui_layout): the deltas since the last one, in one Clay update.
chrome_scroll_flush :: proc() {
	if !pending.any do return
	p := pending
	pending = {}
	clay.SetPointerState(p.at, false)
	clay.UpdateScrollContainers(false, p.delta * SCROLL_STEP * app.dpi, 1.0 / 60)
}
