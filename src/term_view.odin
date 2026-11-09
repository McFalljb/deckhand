package main

// The window's side of a terminal (design §10.2, M2-A; M3-H): what it draws and how input reaches
// the program. The core's side (core/term.odin) owns its ghostty terminal, the PTY and the
// program's status; the window draws, selects, finds links and encodes keys and the mouse on its
// own copy (Term_View.gt), which the core's stream keeps equal to the core's
// (term_view_stream.odin). Input goes back on that stream: the window never writes to the PTY.
// The window works out the grid from its pane and font (term_fit_rect) and asks the core for it.

import "base:runtime"
import "core:math"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "core"
import gh "ghostty"
import sapp "../vendor/sokol-odin/sokol/app"

// The view's render state and encoders (its terminal comes with its first snapshot).
term_view_init :: proc(t: ^Term_View) {
	gh.render_state_new(nil, &t.rs)
	gh.render_state_row_iterator_new(nil, &t.it)
	gh.render_state_row_cells_new(nil, &t.cells)
	gh.key_encoder_new(nil, &t.kenc)
	gh.key_event_new(nil, &t.kev)
	gh.mouse_encoder_new(nil, &t.menc)
	gh.mouse_event_new(nil, &t.mev)
	t.focused = true
}

// Frees what term_view_init made, a drag's tracked ends and the link, then the view's copy of the
// terminal (and a snapshot's history still decoding into it).
term_view_free :: proc(t: ^Term_View) {
	drag_end(t)
	term_link_clear(t)
	if t.dec != nil do gh.snapshot_decoder_free(t.dec)
	t.dec = nil
	if t.dec_blob != nil do delete(t.dec_blob, runtime.heap_allocator())
	t.dec_blob = nil
	if t.gt != nil do gh.terminal_free(t.gt)
	t.gt = nil
	gh.mouse_event_free(t.mev)
	gh.mouse_encoder_free(t.menc)
	gh.key_event_free(t.kev)
	gh.key_encoder_free(t.kenc)
	gh.render_state_row_cells_free(t.cells)
	gh.render_state_row_iterator_free(t.it)
	gh.render_state_free(t.rs)
}

// Pixels between the pane edge and the cell grid.
term_pad :: proc() -> f32 {return f32(TERM_PAD) * app.dpi}

rgba :: proc(c: gh.Color_Rgb, a: u8 = 255) -> core.Rgba {return {c.r, c.g, c.b, a}}

Glyph_Draw :: struct {
	x, y:  f32, // cell top-left
	run:   u32, // shaped run (font.odin)
	cells: int,
	col:   core.Rgba,
}

// Draws the whole grid (inside draw_begin/draw_end).
term_draw :: proc(t: ^Term_View) {
	if t.gt == nil do return // its snapshot has not come yet
	gh.render_state_update(t.rs, t.gt)
	colors := gh.Render_Colors{size = size_of(gh.Render_Colors)}
	gh.render_state_get(t.rs, .Colors, &colors)
	cursor := gh.Render_Cursor{size = size_of(gh.Render_Cursor)}
	gh.render_state_get(t.rs, .Cursor, &cursor)

	draw_rect(t.x, t.y, t.w, t.h, rgba(colors.background))
	ox, oy := t.x + term_pad(), t.y + term_pad()
	glyphs := make([dynamic]Glyph_Draw, 0, int(t.cols) * int(t.rows), context.temp_allocator)
	cursor_glyph: Glyph_Draw
	cursor_has_glyph := false
	lt := font.line_thick

	gh.render_state_get(t.rs, .Row_Iterator, &t.it)
	t.drawn_selected = 0
	row := 0
	for gh.render_state_row_iterator_next(t.it) {
		gh.render_state_row_get(t.it, .Cells, &t.cells)
		y := oy + f32(row) * font.cell_h
		col := 0
		for gh.render_state_row_cells_next(t.cells) {
			defer col += 1
			x := ox + f32(col) * font.cell_w
			raw: gh.Cell
			gh.render_state_row_cells_get(t.cells, .Raw, &raw)
			wide: gh.Cell_Wide
			gh.cell_get(raw, .Wide, &wide)
			if wide == .Spacer_Tail || wide == .Spacer_Head do continue
			span := wide == .Wide ? 2 : 1

			style := gh.Style{size = size_of(gh.Style)}
			gh.render_state_row_cells_get(t.cells, .Style, &style)
			fg, bg := colors.foreground, colors.background
			has_bg := false
			if gh.render_state_row_cells_get(t.cells, .Fg_Color, &fg) != .Success do fg = colors.foreground
			if gh.render_state_row_cells_get(t.cells, .Bg_Color, &bg) == .Success do has_bg = true
			else do bg = colors.background
			selected: bool
			gh.render_state_row_cells_get(t.cells, .Selected, &selected)
			if style.inverse {
				fg, bg = bg, fg
				has_bg = true
			}
			if selected {
				t.drawn_selected += 1
				// the look's selection colour; text keeps its colour
				sc := theme().term_selection
				bg = {sc.r, sc.g, sc.b}
				has_bg = true
			}
			if has_bg do draw_rect(x, y, font.cell_w * f32(span), font.cell_h, rgba(bg))

			// the whole grapheme (ZWJ sequences, flags, skin tones, combining marks)
			n: u32
			gh.render_state_row_cells_get(t.cells, .Graphemes_Len, &n)
			buf: [16]rune
			cps := buf[:0]
			if n > 0 && n <= len(buf) {
				gh.render_state_row_cells_get(t.cells, .Graphemes_Buf, &buf[0])
				cps = buf[:n]
			} else if n > 0 {
				buf[0] = 0xFFFD
				cps = buf[:1]
			}
			alpha: u8 = style.faint ? 140 : 255
			blank := len(cps) == 0 || (len(cps) == 1 && cps[0] == ' ')
			gd := Glyph_Draw{x = x, y = y, cells = span, col = rgba(fg, alpha)}
			if !blank do gd.run = text_cell_run(cps, style.bold, style.italic, span)
			at_cursor := cursor.visible && cursor.viewport_has_value && int(cursor.viewport_x) == col && int(cursor.viewport_y) == row
			if at_cursor {
				cursor_glyph = gd
				cursor_has_glyph = !blank && !style.invisible
			}
			if !blank && !style.invisible do append(&glyphs, gd)

			if style.underline != 0 || style.strikethrough || style.overline {
				uc := rgba(fg, alpha)
				if style.underline_color.tag == .Rgb do uc = rgba(style.underline_color.value.rgb, alpha)
				else if style.underline_color.tag == .Palette do uc = rgba(colors.palette[style.underline_color.value.palette], alpha)
				w := font.cell_w * f32(span)
				uy := y + font.underline_y
				switch style.underline {
				case 0:
				case 2: // double
					draw_rect(x, uy, w, lt, uc)
					draw_rect(x, min(uy + 2 * lt, y + font.cell_h - lt), w, lt, uc)
				case 3: // curly: a small zigzag of steps
					step := max(1, lt)
					amp := max(2, 2 * lt)
					for i := f32(0); i < w; i += step {
						ph := math.mod(x + i, 4 * amp) / (4 * amp) // 0..1 per wave
						d := ph < 0.5 ? ph * 2 : 2 - ph * 2
						draw_rect(x + i, uy - amp / 2 + d * amp, step, lt, uc)
					}
				case 4: // dotted
					for i := f32(0); i < w; i += 2 * lt do draw_rect(x + i, uy, lt, lt, uc)
				case 5: // dashed
					dash := max(2, font.cell_w / 2)
					for i := f32(0); i < w; i += font.cell_w do draw_rect(x + i, uy, min(dash, w - i), lt, uc)
				case:
					draw_rect(x, uy, w, lt, uc)
				}
				if style.strikethrough do draw_rect(x, y + font.strike_y, w, lt, rgba(fg, alpha))
				if style.overline do draw_rect(x, y, w, lt, rgba(fg, alpha))
			}
		}
		row += 1
	}
	for g in glyphs do draw_run(g.run, g.x, g.y + font.baseline, g.col)
	term_link_draw(t, ox, oy, rgba(colors.foreground)) // a link under the pointer while ⌘ is held

	if cursor.viewport_has_value do t.cursor_px = {ox + f32(cursor.viewport_x) * font.cell_w, oy + f32(cursor.viewport_y) * font.cell_h}
	if cursor.visible && cursor.viewport_has_value {
		cx := ox + f32(cursor.viewport_x) * font.cell_w
		cy := oy + f32(cursor.viewport_y) * font.cell_h
		cc := colors.cursor_has_value ? colors.cursor : colors.foreground
		cw := font.cell_w * f32(max(1, cursor_glyph.cells))
		style := cursor.visual_style
		if !t.focused do style = .Block_Hollow
		switch style {
		case .Block:
			draw_rect(cx, cy, cw, font.cell_h, rgba(cc))
			if cursor_has_glyph do draw_run(cursor_glyph.run, cx, cy + font.baseline, rgba(colors.background))
		case .Block_Hollow:
			draw_rect(cx, cy, cw, lt, rgba(cc))
			draw_rect(cx, cy + font.cell_h - lt, cw, lt, rgba(cc))
			draw_rect(cx, cy, lt, font.cell_h, rgba(cc))
			draw_rect(cx + cw - lt, cy, lt, font.cell_h, rgba(cc))
		case .Bar:
			draw_rect(cx, cy, max(2, math.round(font.cell_w / 8)), font.cell_h, rgba(cc))
		case .Underline:
			draw_rect(cx, cy + font.cell_h - 2 * lt, cw, 2 * lt, rgba(cc))
		}
	}
	dirty := gh.Render_Dirty.False
	gh.render_state_set(t.rs, .Dirty, &dirty)
}

// ---- keyboard ----

// sokol keycode -> ghostty key + the unshifted codepoint (US layout).
map_key :: proc(k: sapp.Keycode) -> (gh.Key, rune) {
	#partial switch k {
	case .A ..= .Z:
		return gh.Key(int(gh.Key.A) + int(k) - int(sapp.Keycode.A)), rune('a' + int(k) - int(sapp.Keycode.A))
	case ._0 ..= ._9:
		return gh.Key(int(gh.Key.Digit_0) + int(k) - int(sapp.Keycode._0)), rune('0' + int(k) - int(sapp.Keycode._0))
	case .SPACE:         return .Space, ' '
	case .APOSTROPHE:    return .Quote, '\''
	case .COMMA:         return .Comma, ','
	case .MINUS:         return .Minus, '-'
	case .PERIOD:        return .Period, '.'
	case .SLASH:         return .Slash, '/'
	case .SEMICOLON:     return .Semicolon, ';'
	case .EQUAL:         return .Equal, '='
	case .LEFT_BRACKET:  return .Bracket_Left, '['
	case .BACKSLASH:     return .Backslash, '\\'
	case .RIGHT_BRACKET: return .Bracket_Right, ']'
	case .GRAVE_ACCENT:  return .Backquote, '`'
	case .ESCAPE:        return .Escape, 0
	case .ENTER:         return .Enter, 0
	case .TAB:           return .Tab, 0
	case .BACKSPACE:     return .Backspace, 0
	case .INSERT:        return .Insert, 0
	case .DELETE:        return .Delete, 0
	case .RIGHT:         return .Arrow_Right, 0
	case .LEFT:          return .Arrow_Left, 0
	case .DOWN:          return .Arrow_Down, 0
	case .UP:            return .Arrow_Up, 0
	case .PAGE_UP:       return .Page_Up, 0
	case .PAGE_DOWN:     return .Page_Down, 0
	case .HOME:          return .Home, 0
	case .END:           return .End, 0
	case .F1 ..= .F12:
		return gh.Key(int(gh.Key.F1) + int(k) - int(sapp.Keycode.F1)), 0
	case .KP_ENTER:      return .Numpad_Enter, 0
	case .LEFT_SHIFT:    return .Shift_Left, 0
	case .RIGHT_SHIFT:   return .Shift_Right, 0
	case .LEFT_CONTROL:  return .Control_Left, 0
	case .RIGHT_CONTROL: return .Control_Right, 0
	case .LEFT_ALT:      return .Alt_Left, 0
	case .RIGHT_ALT:     return .Alt_Right, 0
	case .LEFT_SUPER:    return .Meta_Left, 0
	case .RIGHT_SUPER:   return .Meta_Right, 0
	}
	return .Unidentified, 0
}

to_mods :: proc(m: u32) -> gh.Mods {
	out: gh.Mods
	if m & sapp.MODIFIER_SHIFT != 0 do out |= gh.MOD_SHIFT
	if m & sapp.MODIFIER_CTRL != 0 do out |= gh.MOD_CTRL
	if m & sapp.MODIFIER_ALT != 0 do out |= gh.MOD_ALT
	if m & sapp.MODIFIER_SUPER != 0 do out |= gh.MOD_SUPER
	return out
}

@(private = "file")
send_key :: proc(t: ^Term_View, action: gh.Key_Action, key: gh.Key, mods: gh.Mods, unshifted: rune, text: string) {
	if t.gt == nil do return
	gh.key_encoder_setopt_from_terminal(t.kenc, t.gt)
	opt := core.OPTION_AS_ALT
	gh.key_encoder_setopt(t.kenc, .Macos_Option_As_Alt, &opt)
	gh.key_event_set_action(t.kev, action)
	gh.key_event_set_key(t.kev, key)
	gh.key_event_set_mods(t.kev, mods)
	gh.key_event_set_consumed_mods(t.kev, text != "" ? mods & gh.MOD_SHIFT : 0)
	gh.key_event_set_unshifted_codepoint(t.kev, u32(unshifted))
	gh.key_event_set_utf8(t.kev, raw_data(text), len(text))
	out: [128]u8
	n: uint
	if gh.key_encoder_encode(t.kenc, t.kev, &out[0], len(out), &n) == .Success && n > 0 {
		term_view_input(t, out[:n])
		view_scroll_bottom(t)
	}
}

// macOS text-editing keys: Ghostty's macOS default keybinds (src/config/
// Config.zig at the pinned v1.4.0, "natural text editing"), fixed bytes that
// skip the key encoder so shells (zsh, readline) and pi's editor get the same
// legacy form in any keyboard mode:
//   ⌘⌫ Ctrl-U (delete to line start), ⌘← Ctrl-A, ⌘→ Ctrl-E, ⌥← ESC b, ⌥→ ESC f.
// ⌥⌦ (fn+⌥⌫) → ESC d (delete word forward) is ours, Ghostty has no default
// for it; only without the kitty keyboard protocol, as pi reads ESC d as
// alt+d only then (with it on, the encoder's CSI 3;3~ is pi's alt+delete).
// ⌥⌫ needs no entry: the encoder sends ESC DEL (legacy) or CSI 127;3u (kitty),
// as Ghostty does. ⌘K stays the palette (Ghostty: clear screen).
mac_key_text :: proc(k: sapp.Keycode, modifiers: u32, kitty: bool) -> string {
	switch modifiers & (sapp.MODIFIER_SHIFT | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SUPER) {
	case sapp.MODIFIER_SUPER:
		#partial switch k {
		case .BACKSPACE: return "\x15"
		case .LEFT:      return "\x01"
		case .RIGHT:     return "\x05"
		}
	case sapp.MODIFIER_ALT:
		#partial switch k {
		case .LEFT:   return "\x1bb"
		case .RIGHT:  return "\x1bf"
		case .DELETE: if !kitty do return "\x1bd"
		}
	}
	return ""
}

kitty_flags :: proc(t: ^Term_View) -> u8 {
	f: u8
	if t.gt != nil do gh.terminal_get(t.gt, .Kitty_Keyboard_Flags, &f)
	return f
}

term_key_down :: proc(t: ^Term_View, e: ^sapp.Event) {
	if s := mac_key_text(e.key_code, e.modifiers, kitty_flags(t) != 0); s != "" {
		t.char_handled = true
		term_view_input(t, transmute([]u8)s)
		view_scroll_bottom(t)
		return
	}
	key, unshifted := map_key(e.key_code)
	mods := to_mods(e.modifiers)
	action := e.key_repeat ? gh.Key_Action.Repeat : gh.Key_Action.Press
	// Printable keys without Ctrl/Alt wait for their CHAR event, which carries
	// the layout-correct text (shifted symbols, non-US layouts).
	// Keys we cannot name (other layouts, symbols) also travel as text.
	if (unshifted != 0 || key == .Unidentified) && mods & (gh.MOD_CTRL | gh.MOD_ALT) == 0 {
		t.pending_key, t.pending_mods, t.pending_cp = key, mods, unshifted
		t.char_handled = false
		return
	}
	t.char_handled = true
	if key == .Unidentified do return
	send_key(t, action, key, mods, unshifted, "")
}

term_key_up :: proc(t: ^Term_View, e: ^sapp.Event) {
	if t.gt == nil do return
	if mac_key_text(e.key_code, e.modifiers, kitty_flags(t) != 0) != "" do return // its press was text, not a key
	key, unshifted := map_key(e.key_code)
	if key == .Unidentified do return
	send_key(t, .Release, key, to_mods(e.modifiers), unshifted, "")
}

term_char :: proc(t: ^Term_View, e: ^sapp.Event) {
	if t.gt == nil do return
	if t.char_handled do return
	cp := e.char_code
	if cp < 0x20 || cp == 0x7F do return
	if cp >= 0xD800 && cp < 0xDC00 { // UTF-16 high surrogate (sokol sends units)
		t.surrogate = cp
		return
	}
	if cp >= 0xDC00 && cp < 0xE000 {
		if t.surrogate == 0 do return
		cp = 0x10000 + ((t.surrogate - 0xD800) << 10) + (cp - 0xDC00)
		t.surrogate = 0
	}
	buf, n := utf8.encode_rune(rune(cp))
	send_key(t, e.key_repeat ? .Repeat : .Press, t.pending_key, t.pending_mods, t.pending_cp, string(buf[:n]))
}

// The window gained or lost the keyboard: the cursor draws hollow, and the core tells the
// program if it asked (mode 1004: the core's terminal knows, term_stream.odin's FOCUS).
term_focus :: proc(t: ^Term_View, focused: bool) {
	t.focused = focused
	t.changed = true
	term_view_focus_send(t, focused)
}

// ---- mouse ----

in_pane :: proc(t: ^Term_View, mx, my: f32) -> bool {
	return mx >= t.x && mx < t.x + t.w && my >= t.y && my < t.y + t.h
}

cell_at :: proc(t: ^Term_View, mx, my: f32) -> [2]u16 {
	cx := clamp(int((mx - t.x - term_pad()) / font.cell_w), 0, int(t.cols) - 1)
	cy := clamp(int((my - t.y - term_pad()) / font.cell_h), 0, int(t.rows) - 1)
	return {u16(cx), u16(cy)}
}

app_tracks_mouse :: proc(t: ^Term_View) -> bool {
	if t.gt == nil do return false
	mt: gh.Mouse_Tracking
	gh.terminal_get(t.gt, .Mouse_Tracking, &mt)
	return mt != .None
}

@(private = "file")
send_mouse :: proc(t: ^Term_View, action: gh.Mouse_Action, button: gh.Mouse_Button, mx, my: f32, mods: gh.Mods) {
	if t.gt == nil do return
	gh.mouse_encoder_setopt_from_terminal(t.menc, t.gt)
	size := gh.Mouse_Encoder_Size {
		size          = size_of(gh.Mouse_Encoder_Size),
		screen_width  = u32(t.w),
		screen_height = u32(t.h),
		cell_width    = u32(font.cell_w),
		cell_height   = u32(font.cell_h),
		padding_top   = u32(term_pad()),
		padding_left  = u32(term_pad()),
	}
	gh.mouse_encoder_setopt(t.menc, .Size, &size)
	any_pressed := t.mouse_down
	gh.mouse_encoder_setopt(t.menc, .Any_Button_Pressed, &any_pressed)
	gh.mouse_event_set_action(t.mev, action)
	if button == .Unknown do gh.mouse_event_clear_button(t.mev)
	else do gh.mouse_event_set_button(t.mev, button)
	gh.mouse_event_set_mods(t.mev, mods)
	gh.mouse_event_set_position(t.mev, {mx - t.x, my - t.y})
	out: [64]u8
	n: uint
	if gh.mouse_encoder_encode(t.menc, t.mev, &out[0], len(out), &n) == .Success && n > 0 do term_view_input(t, out[:n])
}

// Screen coordinates (scrollback included) of a viewport cell.
@(private = "file")
to_screen :: proc(t: ^Term_View, c: [2]u16) -> [2]u32 {
	p := gh.Point{tag = .Viewport}
	p.value.coordinate = {x = c.x, y = u32(c.y)}
	ref := gh.Grid_Ref{size = size_of(gh.Grid_Ref)}
	out: gh.Point_Coordinate
	if gh.terminal_grid_ref(t.gt, p, &ref) != .Success || gh.terminal_point_from_grid_ref(t.gt, &ref, .Screen, &out) != .Success do return {u32(c.x), u32(c.y)}
	return {u32(out.x), out.y}
}

@(private = "file")
set_selection :: proc(t: ^Term_View, a, b: [2]u32) {
	ra, rb := gh.Grid_Ref{size = size_of(gh.Grid_Ref)}, gh.Grid_Ref{size = size_of(gh.Grid_Ref)}
	pa := gh.Point{tag = .Screen}
	pa.value.coordinate = {x = u16(a.x), y = a.y}
	pb := gh.Point{tag = .Screen}
	pb.value.coordinate = {x = u16(b.x), y = b.y}
	if gh.terminal_grid_ref(t.gt, pa, &ra) != .Success || gh.terminal_grid_ref(t.gt, pb, &rb) != .Success do return
	sel := gh.Selection{size = size_of(gh.Selection), start = ra, end = rb}
	gh.terminal_set(t.gt, .Selection, &sel)
	t.changed = true
}

// Where the current selection started (screen coordinates), if there is one.
@(private = "file")
selection_start :: proc(t: ^Term_View) -> ([2]u32, bool) {
	sel := gh.Selection{size = size_of(gh.Selection)}
	if gh.terminal_get(t.gt, .Selection, &sel) != .Success do return {}, false
	out: gh.Point_Coordinate
	if gh.terminal_point_from_grid_ref(t.gt, &sel.start, .Screen, &out) != .Success do return {}, false
	return {u32(out.x), out.y}, true
}

clear_selection :: proc(t: ^Term_View) {
	if t.gt == nil do return
	gh.terminal_set(t.gt, .Selection, nil)
	t.changed = true
}

to_button :: proc(b: sapp.Mousebutton) -> gh.Mouse_Button {
	#partial switch b {
	case .LEFT:   return .Left
	case .RIGHT:  return .Right
	case .MIDDLE: return .Middle
	}
	return .Unknown
}

// Mouse in the pane, as Ghostty and iTerm do it: reported to the app when it
// tracks the mouse (Shift overrides and selects; a reported press clears our
// selection), otherwise the left button selects: drag for cells,
// double-click for a word, triple-click for a line (a drag after them
// extends by words or lines), Shift+click extends the selection there. The
// selection is drawn as it changes, every move of the drag.
term_mouse_down :: proc(t: ^Term_View, e: ^sapp.Event, clicks: int) {
	if t.gt == nil do return
	mods := to_mods(e.modifiers)
	drag_end(t)
	t.mouse_down = true
	t.mouse_button = .Unknown // set only for a press the app was sent
	if app_tracks_mouse(t) && mods & gh.MOD_SHIFT == 0 {
		if _, has := selection_start(t); has do clear_selection(t)
		t.mouse_button = to_button(e.mouse_button)
		send_mouse(t, .Press, t.mouse_button, e.mouse_x, e.mouse_y, mods)
		return
	}
	if e.mouse_button != .LEFT do return
	vc := cell_at(t, e.mouse_x, e.mouse_y)
	c := to_screen(t, vc)
	t.selecting = true
	t.drag_at = {e.mouse_x, e.mouse_y}
	t.sel_unit = clamp(clicks, 1, 3)
	if a, has := selection_start(t); has && t.sel_unit == 1 && mods & gh.MOD_SHIFT != 0 {
		track(t, SEL_ANCHOR, a)
		set_selection(t, a, c)
		return
	}
	track(t, SEL_ANCHOR, c)
	lo, hi: [2]u32
	switch t.sel_unit {
	case 1:
		clear_selection(t)
		return
	case 2:
		vlo, vhi := word_cells(t, vc)
		lo, hi = to_screen(t, vlo), to_screen(t, vhi)
	case 3:
		lo, hi = {0, c.y}, {u32(t.cols) - 1, c.y}
	}
	track(t, SEL_LO, lo)
	track(t, SEL_HI, hi)
	set_selection(t, lo, hi)
}

SEL_ANCHOR :: 0
SEL_LO :: 1
SEL_HI :: 2

// Remembers screen point p as the drag's end i (SEL_*), on its text.
@(private = "file")
track :: proc(t: ^Term_View, i: int, p: [2]u32) {
	gh.tracked_grid_ref_free(t.sel_refs[i])
	t.sel_refs[i] = nil
	pt := gh.Point{tag = .Screen}
	pt.value.coordinate = {x = u16(p.x), y = p.y}
	gh.terminal_grid_ref_track(t.gt, pt, &t.sel_refs[i])
}

// Where the drag's end i is now (screen coordinates); false if its row is gone.
@(private = "file")
tracked :: proc(t: ^Term_View, i: int) -> ([2]u32, bool) {
	if t.sel_refs[i] == nil do return {}, false
	out: gh.Point_Coordinate
	if gh.tracked_grid_ref_point(t.sel_refs[i], .Screen, &out) != .Success do return {}, false
	return {u32(out.x), out.y}, true
}

// The drag is over (the selection stays): its tracked ends are freed.
@(private = "file")
drag_end :: proc(t: ^Term_View) {
	t.selecting = false
	for &r in t.sel_refs {
		gh.tracked_grid_ref_free(r)
		r = nil
	}
}

// A drag cut short (tab or session change, the window lost focus): no more
// selecting or auto-scroll, and no release for the app either.
term_cancel_drag :: proc(t: ^Term_View) {
	drag_end(t)
	t.mouse_down = false
	t.mouse_button = .Unknown
}

term_mouse_up :: proc(t: ^Term_View, e: ^sapp.Event) {
	if t.gt == nil do return
	if !t.mouse_down do return // press was outside the pane
	t.mouse_down = false
	if t.selecting {
		drag_end(t)
		return
	}
	pressed := t.mouse_button
	t.mouse_button = .Unknown
	if pressed != .Unknown && app_tracks_mouse(t) do send_mouse(t, .Release, to_button(e.mouse_button), e.mouse_x, e.mouse_y, to_mods(e.modifiers))
}

term_mouse_move :: proc(t: ^Term_View, e: ^sapp.Event) {
	if t.gt == nil do return
	if t.selecting {
		t.drag_at = {e.mouse_x, e.mouse_y}
		select_to(t, cell_at(t, e.mouse_x, e.mouse_y))
		return
	}
	if !app_tracks_mouse(t) do return
	c := cell_at(t, e.mouse_x, e.mouse_y)
	cell := [2]i32{i32(c.x), i32(c.y)}
	if cell == t.mouse_cell do return // only report cell changes
	t.mouse_cell = cell
	// a drag reports its button (SGR 32+0 for the left one): apps that only
	// track button motion (1002, pi) ignore motion without one
	send_mouse(t, .Motion, t.mouse_down ? t.mouse_button : .Unknown, e.mouse_x, e.mouse_y, to_mods(e.modifiers))
}

// The selection drag reached viewport cell vc.
@(private = "file")
select_to :: proc(t: ^Term_View, vc: [2]u16) {
	c := to_screen(t, vc)
	anchor, ok := tracked(t, SEL_ANCHOR)
	if !ok do return // its row left the scrollback
	if t.sel_unit == 1 {
		if c != anchor do set_selection(t, anchor, c)
		return
	}
	sel_lo, ok_lo := tracked(t, SEL_LO)
	sel_hi, ok_hi := tracked(t, SEL_HI)
	if !ok_lo || !ok_hi do return
	if t.sel_unit == 2 {
		vlo, vhi := word_cells(t, vc)
		lo, hi := to_screen(t, vlo), to_screen(t, vhi)
		if before(c, sel_lo) do set_selection(t, lo, sel_hi)
		else do set_selection(t, sel_lo, before(hi, sel_hi) ? sel_hi : hi)
	} else {
		if c.y < sel_lo.y do set_selection(t, {0, c.y}, sel_hi)
		else do set_selection(t, sel_lo, {u32(t.cols) - 1, max(c.y, sel_hi.y)})
	}
}

AUTOSCROLL_STEP :: 50 * time.Millisecond

// Every frame: while a selection drag is above or below the grid, the
// viewport scrolls a row per AUTOSCROLL_STEP and the selection follows.
// left_down: the left button is down now; if not, the release never came
// and the drag ends. Nothing to do (no redraw) without a drag.
term_drag_tick :: proc(t: ^Term_View, left_down: bool) {
	if !t.selecting || t.gt == nil || t.rows == 0 do return
	if !left_down {
		term_cancel_drag(t)
		return
	}
	top := t.y + term_pad()
	dir := 0
	if t.drag_at.y < top do dir = -1
	else if t.drag_at.y >= top + f32(t.rows) * font.cell_h do dir = 1
	if dir == 0 || time.tick_since(t.drag_scrolled) < AUTOSCROLL_STEP do return
	t.drag_scrolled = time.tick_now()
	before_sb, after_sb := gh.Scrollbar{}, gh.Scrollbar{}
	gh.terminal_get(t.gt, .Scrollbar, &before_sb)
	sv := gh.Scroll_Viewport{tag = .Delta}
	sv.value.delta = dir
	gh.terminal_scroll_viewport(t.gt, sv)
	gh.terminal_get(t.gt, .Scrollbar, &after_sb)
	if after_sb.offset == before_sb.offset do return // at the top or bottom already
	select_to(t, cell_at(t, t.drag_at.x, t.drag_at.y))
	t.changed = true
}

// a before b in reading order
@(private = "file")
before :: proc(a, b: [2]u32) -> bool {return a.y < b.y || (a.y == b.y && a.x < b.x)}

// Characters that end a word for double-click selection besides spaces
// (Ghostty's default selection-word-chars).
WORD_BREAKS :: " \t'\"│`|:;,()[]{}<>$"

// The cells of the word under c (or of the run of spaces, or the single
// break character), on c's row.
word_cells :: proc(t: ^Term_View, c: [2]u16) -> (lo, hi: [2]u16) {
	row := row_runes(t, int(c.y))
	if len(row) == 0 do return c, c
	x := min(int(c.x), len(row) - 1)
	for x > 0 && row[x] == SPACER do x -= 1
	class :: proc(r: rune) -> int {
		if r == 0 || r == ' ' do return 0
		if strings.contains_rune(WORD_BREAKS, r) do return 1
		return 2
	}
	k := class(row[x])
	// a wide character's spacer cell belongs to the character before it
	same :: proc(r: rune, k: int) -> bool {return r == SPACER ? k != 0 : class(r) == k}
	a, b := x, x
	if k != 1 {
		for a > 0 && same(row[a - 1], k) do a -= 1
		for b + 1 < len(row) && same(row[b + 1], k) do b += 1
	} else if b + 1 < len(row) && row[b + 1] == SPACER do b += 1
	return {u16(a), c.y}, {u16(b), c.y}
}

SPACER :: rune(-1) // row_runes: the second cell of a wide character

// One viewport row as one rune per cell (0 for empty cells, SPACER for wide
// characters' second cells; else the grapheme's first codepoint).
row_runes :: proc(t: ^Term_View, y: int) -> []rune {
	if t.gt == nil do return nil
	gh.render_state_update(t.rs, t.gt)
	gh.render_state_get(t.rs, .Row_Iterator, &t.it)
	out := make([dynamic]rune, context.temp_allocator)
	row := 0
	for gh.render_state_row_iterator_next(t.it) {
		defer row += 1
		if row != y do continue
		gh.render_state_row_get(t.it, .Cells, &t.cells)
		for gh.render_state_row_cells_next(t.cells) {
			raw: gh.Cell
			gh.render_state_row_cells_get(t.cells, .Raw, &raw)
			wide: gh.Cell_Wide
			gh.cell_get(raw, .Wide, &wide)
			if wide == .Spacer_Tail || wide == .Spacer_Head {
				append(&out, SPACER)
				continue
			}
			n: u32
			gh.render_state_row_cells_get(t.cells, .Graphemes_Len, &n)
			if n == 0 {
				append(&out, 0)
				continue
			}
			buf: [16]u32
			if n <= len(buf) do gh.render_state_row_cells_get(t.cells, .Graphemes_Buf, &buf[0])
			append(&out, rune(buf[0]))
		}
	}
	t.changed = true // the render state was consumed here; redraw
	return out[:]
}

// Text an input method committed: typed into the terminal as UTF-8.
term_text_input :: proc(t: ^Term_View, text: string) {
	if text == "" do return
	term_view_input(t, transmute([]u8)text)
	view_scroll_bottom(t)
}

// An input method's composition at the cursor: drawn over the cells,
// underlined, with a caret.
term_draw_marked :: proc(t: ^Term_View, marked: string, caret: int) {
	if marked == "" do return
	tc := core.term_colors()
	x, y := t.cursor_px.x, t.cursor_px.y
	w := text_width(marked, .Mono)
	draw_rect(x, y, w, font.cell_h, tc.bg)
	draw_text(x, y, marked, tc.fg, .Mono)
	draw_rect(x, y + font.cell_h - font.line_thick, w, font.line_thick, tc.fg)
	draw_rect(x + text_width(marked[:clamp(caret, 0, len(marked))], .Mono), y, max(1, font.line_thick), font.cell_h, tc.cursor)
}

// Wheel: to the app as button 4/5 when it tracks the mouse, as arrow keys on
// the alternate screen, else scrolls our scrollback. Trackpads deliver
// fractional deltas, so whole steps are accumulated.
term_scroll :: proc(t: ^Term_View, e: ^sapp.Event) {
	if t.gt == nil do return
	t.scroll_acc += e.scroll_y
	steps := int(t.scroll_acc)
	if steps == 0 do return
	t.scroll_acc -= f32(steps)
	mods := to_mods(e.modifiers)
	if app_tracks_mouse(t) {
		for _ in 0 ..< abs(steps) do send_mouse(t, .Press, steps > 0 ? .Four : .Five, e.mouse_x, e.mouse_y, mods)
		return
	}
	screen: gh.Terminal_Screen
	gh.terminal_get(t.gt, .Active_Screen, &screen)
	if screen == .Alternate {
		for _ in 0 ..< abs(steps) do send_key(t, .Press, steps > 0 ? .Arrow_Up : .Arrow_Down, 0, 0, "")
		return
	}
	sv := gh.Scroll_Viewport{tag = .Delta}
	sv.value.delta = -steps
	gh.terminal_scroll_viewport(t.gt, sv)
	t.changed = true
}
