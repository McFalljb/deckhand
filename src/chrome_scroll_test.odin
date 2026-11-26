package main

// A trackpad scroll of the left column: macOS sends several wheel events per frame (precise
// deltas, then momentum). The list goes steadily down, never back to the top in between.

import "base:runtime"
import "core:fmt"
import "core:testing"
import "core"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

@(private = "file")
cs_ui :: proc() -> bool {
	@(static) ready: bool
	if ready do return true
	app.dpi = 1
	font.size = ATLAS_MIN
	font.pixels = make([]u8, ATLAS_MIN * ATLAS_MIN * 4)
	if !fonts_apply(theme_font_config(theme()), 1) do return false
	ui_init()
	ready = true
	return true
}

@(test)
sidebar_trackpad_scroll_is_monotonic :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state^ = core.State {
		layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true, right_open = true},
	}
	if !testing.expect(t, cs_ui(), "fonts") do return
	for i in 0 ..< 150 do append(&state.projects, core.Project{id = u64(1000 + i), group = .Projects, cwd = fmt.aprintf("/pd-test/p%d", i), label = fmt.aprintf("project %d", i)})
	defer clear(&state.projects)
	_ = ui_layout(1400, 860)
	b := clay.GetElementData(clay.ID("nav")).boundingBox
	if !testing.expect(t, b.height > 0, "the list is laid out") do return
	at := [2]f32{b.x + b.width / 2, b.y + b.height / 2}
	last: f32 = 0
	for frame in 0 ..< 20 { // at most 120 px a frame: within the list (about 4000 px)
		// one to three precise deltas between two frames, as main.odin's event gets them
		wheel := sapp.Event{type = .MOUSE_SCROLL, mouse_x = at.x, mouse_y = at.y, scroll_y = -0.4}
		for _ in 0 ..< 1 + frame % 3 do chrome_scroll_event(&wheel)
		_ = ui_layout(1400, 860)
		d := clay.GetScrollContainerData(clay.ID("nav"))
		if !testing.expect(t, d.found, "the list scrolls") do return
		y := d.scrollPosition.y
		testing.expectf(t, y < last, "frame %d: the offset went on down (%v after %v)", frame, y, last)
		last = y
	}
	// the deltas are applied once, at the next layout: none is left over
	_ = ui_layout(1400, 860)
	testing.expectf(t, clay.GetScrollContainerData(clay.ID("nav")).scrollPosition.y == last, "a layout without the wheel stays put")
}
