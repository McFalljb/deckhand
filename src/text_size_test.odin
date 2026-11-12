package main

// The gear's text size (Settings.text_size): the command, its JSON, saving and
// restoring it, the fonts it opens, proportional measuring at each size (text
// field caret and clicks, ellipsis), the gear's keyboard order. The layout at
// every size is checked in layout_audit_test.odin.

import "base:runtime"
import "core:strings"
import "core:testing"
import "core"

@(private = "file")
ts_fonts :: proc(size: core.Text_Size) -> bool {
	if font.pixels == nil {
		font.size = ATLAS_MIN
		font.pixels = make([]u8, ATLAS_MIN * ATLAS_MIN * 4)
	}
	state.settings.text_size = size
	return fonts_apply(theme_font_config(theme()), 1)
}

@(test)
text_size_command :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state^ = core.State{}
	core.persist = {}
	defer state.settings.text_size = .Default
	// JSON both ways
	for c in ([]core.Command{core.Set_Text_Size{.Small}, core.Set_Text_Size{.Medium}, core.Set_Text_Size{.Default}, core.Set_Text_Size{.Large}}) {
		text := core.command_json(c)
		back, err := core.parse_command(text, context.temp_allocator)
		testing.expectf(t, err == "", "%s: %s", text, err)
		testing.expectf(t, core.command_json(back) == text, "round trip: %s -> %s", text, core.command_json(back))
	}
	testing.expect_value(t, core.command_json(core.Set_Text_Size{.Large}), `{"type":"set_text_size","size":"large"}`)
	_, err := core.parse_command(`{"type":"set_text_size","size":"huge"}`, context.temp_allocator)
	testing.expect_value(t, err, "unknown size huge")
	// anyone but a panel; unchanged = no new version
	v := state.version
	r := core.run_command(core.Set_Text_Size{.Large}, core.Caller{kind = .Script})
	testing.expect(t, r.ok, r.error)
	testing.expect_value(t, state.settings.text_size, core.Text_Size.Large)
	testing.expect_value(t, state.version, v + 1)
	core.run_command(core.Set_Text_Size{.Large}, core.Caller{kind = .Script})
	testing.expect_value(t, state.version, v + 1)
	r = core.run_command(core.Set_Text_Size{.Small}, core.Caller{kind = .Panel})
	testing.expect_value(t, r.error, "not allowed for this caller")
	g := core.run_command(core.Get_State{}, core.Caller{kind = .Script})
	testing.expect(t, strings.contains(g.data, `"text_size":"large"`), g.data)
	// the palette's actions
	testing.expect(t, action_by_id("text_small") != nil && action_by_id("text_large") != nil)
	action_run("text_medium")
	core.inbox_drain()
	testing.expect_value(t, state.settings.text_size, core.Text_Size.Medium)
}

@(test)
text_size_saved :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state^ = core.State{}
	core.persist = {}
	defer state.settings.text_size = .Default
	// the default is not written
	testing.expect(t, !strings.contains(core.workspace_json(), "text_size"), core.workspace_json())
	core.run_command(core.Set_Text_Size{.Large})
	saved := strings.clone(core.workspace_json())
	testing.expect(t, strings.contains(saved, `"text_size":"large"`), saved)
	state^ = core.State{}
	core.persist = {}
	err := core.workspace_restore(saved)
	testing.expect_value(t, err, "")
	testing.expect_value(t, state.settings.text_size, core.Text_Size.Large)
	// an unknown size is ignored (the default stays)
	state^ = core.State{}
	core.persist = {}
	bad, _ := strings.replace_all(saved, `"text_size":"large"`, `"text_size":"huge"`, context.temp_allocator)
	testing.expect_value(t, core.workspace_restore(bad), "")
	testing.expect_value(t, state.settings.text_size, core.Text_Size.Default)
}

@(test)
text_size_fonts :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state^ = core.State{}
	core.app_context = context
	defer {
		state.settings.text_size = .Default
		fonts_apply(theme_font_config(theme()), 1)
	}
	body, small, width: [core.Text_Size]f32
	faces: [core.Text_Size]Face_Id
	cell_w, cell_h: [core.Text_Size]f32
	for size in core.Text_Size {
		if !testing.expect(t, ts_fonts(size), "fonts") do return
		testing.expect_value(t, font.sets[.UI].px, TYPE_UI_PX[size][0])
		testing.expect_value(t, font.sets[.UI_Small].px, TYPE_UI_PX[size][1])
		body[size], small[size] = text_line_height(.UI), text_line_height(.UI_Small)
		width[size] = text_width("Keyboard shortcuts", .UI)
		faces[size] = font.sets[.UI].faces[0]
		cell_w[size], cell_h[size] = font.cell_w, font.cell_h
		// proportional: narrow letters take less room than wide ones
		testing.expectf(t, text_width("iiiiiiii", .UI) < 0.6 * text_width("MMMMMMMM", .UI), "%v: proportional UI font", size)
		// the terminal's font is not the UI's
		testing.expectf(t, text_width("iiiiiiii", .Mono) == text_width("MMMMMMMM", .Mono), "%v: monospaced terminal font", size)
	}
	// bigger steps, bigger text; terminals keep their cells
	order := TEXT_SIZE_ORDER
	for i in 1 ..< len(order) {
		a, b := order[i - 1], order[i]
		testing.expectf(t, width[a] < width[b], "%v < %v: width %v %v", a, b, width[a], width[b])
		testing.expectf(t, body[a] <= body[b] && small[a] <= small[b], "%v <= %v: line heights", a, b)
		testing.expect_value(t, cell_w[b], cell_w[a])
		testing.expect_value(t, cell_h[b], cell_h[a])
	}
	// each size has its own face, so its own glyphs in the atlas (the raster
	// key holds the face)
	for a in core.Text_Size do for b in core.Text_Size do if a != b {
		testing.expectf(t, faces[a] != faces[b], "%v and %v share a face", a, b)
	}
}

// The text field's caret, selection and clicks measure prefixes of the
// shaped run, at every size; ellipsis cuts fit.
@(test)
text_size_field_math :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state^ = core.State{}
	core.app_context = context
	defer {
		state.settings.text_size = .Default
		fonts_apply(theme_font_config(theme()), 1)
	}
	s := "Will it fit? Wide MW, thin il, ünïcödé"
	for size in core.Text_Size {
		if !testing.expect(t, ts_fonts(size), "fonts") do return
		prev := f32(-1)
		for _, off in s {
			x := text_width(s[:off], .UI)
			testing.expectf(t, x > prev || off == 0, "%v: prefix widths grow (%d)", size, off)
			prev = x
			// a click just right of a boundary lands on it
			testing.expectf(t, text_offset_at(s, x + 0.5, .UI) == off, "%v: click at %.1f -> %d, want %d", size, x + 0.5, text_offset_at(s, x + 0.5, .UI), off)
		}
		testing.expect_value(t, text_offset_at(s, text_width(s, .UI) + 10, .UI), len(s))
		// rune prefixes (text_prefix_width) match byte prefixes
		testing.expect_value(t, text_prefix_width(s, 4, .UI), text_width(s[:4], .UI))
		// proportional: "il" is narrower than "MW"
		testing.expect(t, text_width("il", .UI) < text_width("MW", .UI))
		// ellipsis: the cut fits and ends in "…"
		for max_w in ([]f32{40, 80, 120}) {
			c := text_clip(s, max_w, .UI)
			testing.expectf(t, text_width(c, .UI) <= max_w + 0.5, "%v: %q is %.1f wide, room %.0f", size, c, text_width(c, .UI), max_w)
			testing.expect(t, strings.has_suffix(c, "…"))
		}
	}
}

// The keyboard walks Quick settings' rows top to bottom: each row once, All settings… last.
@(test)
gear_keyboard_order :: proc(t: ^testing.T) {
	seen: [Pop_Item]int
	for it in POP_ORDER do seen[it] += 1
	for it in Pop_Item do testing.expectf(t, seen[it] <= 1, "%v is %d times in POP_ORDER", it, seen[it])
	order := POP_ORDER
	testing.expect_value(t, order[6], Pop_Item.Text_Small) // right under Look
	testing.expect_value(t, order[len(order) - 1], Pop_Item.Settings_Files)
}

// A size change reaches the layout at once: Clay's cached text widths are
// measured again (a section header's width matches the new font's).
@(test)
text_size_relayout :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT, left_open = true, right_open = true}}
	core.app_context = context
	app.dpi = 1
	defer {
		state.settings.text_size = .Default
		fonts_apply(theme_font_config(theme()), 1)
	}
	if !testing.expect(t, ts_fonts(.Default), "fonts") do return
	if ui_memory == nil do ui_init()
	header_w :: proc() -> (w: f32, found: bool) {
		cmds := ui_layout(1400, 860)
		for i in 0 ..< cmds.length {
			c := &cmds.internalArray[i]
			if c.commandType != .Text do continue
			td := c.renderData.text
			if string(td.stringContents.chars[:td.stringContents.length]) == "PROJECTS" do return c.boundingBox.width, true
		}
		return
	}
	_, _ = header_w() // measured at the default size
	for size in ([]core.Text_Size{.Large, .Small, .Default}) {
		ts_fonts(size)
		w, found := header_w()
		if !testing.expectf(t, found, "%v: the Projects header", size) do return
		want := text_w("PROJECTS", FONT_UI_SMALL | WEIGHT_HEADER)
		testing.expectf(t, abs(w - want) < 0.5, "%v: laid out %.1f wide, the font measures %.1f", size, w, want)
	}
}

// Section headers use the UI font's semibold face (SF Pro has one): between
// regular and bold, its own face; a family without one uses bold.
@(test)
semibold_headers :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	state^ = core.State{}
	core.app_context = context
	defer fonts_apply(theme_font_config(theme()), 1)
	if !testing.expect(t, ts_fonts(.Default), "fonts") do return
	for kind in ([]Font_Kind{.UI, .UI_Small}) {
		set := &font.sets[kind]
		s := "PROJECTS Notifications"
		reg, semi, bold := text_width(s, kind), text_width(s, kind, semibold = true), text_width(s, kind, bold = true)
		when TEXT_BACKEND == "coretext" {
			testing.expectf(t, set.faces[4] != set.faces[0] && set.faces[4] != set.faces[1], "%v: a semibold face of its own", kind)
			testing.expectf(t, reg < semi && semi < bold, "%v: widths regular %.1f < semibold %.1f < bold %.1f", kind, reg, semi, bold)
		} else {
			testing.expect_value(t, set.faces[4], set.faces[1])
		}
		// the fontId bit reaches measuring
		testing.expect_value(t, text_w(s, u16(kind) | WEIGHT_HEADER), semi)
	}
}
