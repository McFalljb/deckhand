package tests

// Checks the hand-written libghostty-vt bindings:
//  1. struct sizes/offsets and key enum values against the C compiler
//     (build/abi_sizes.txt, produced by `./build.sh test` from tests/abi_sizes.c);
//  2. an end-to-end pass through the calls pi-desk makes.

import "base:runtime"
import "core:c"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:testing"
import gh "../src/ghostty"

Expect :: struct {
	key: string,
	val: int,
}

@(test)
abi_matches_c :: proc(t: ^testing.T) {
	data, err := os.read_entire_file("build/abi_sizes.txt", context.allocator)
	testing.expect(t, err == nil, "build/abi_sizes.txt missing: run ./build.sh test")
	if err != nil do return
	defer delete(data)
	want := [?]Expect {
		{"Style size", int(size_of(gh.Style))},
		{"Style.bold offset", int(offset_of(gh.Style, bold))},
		{"Style.underline offset", int(offset_of(gh.Style, underline))},
		{"Style_Color size", int(size_of(gh.Style_Color))},
		{"Point size", int(size_of(gh.Point))},
		{"Grid_Ref size", int(size_of(gh.Grid_Ref))},
		{"Selection size", int(size_of(gh.Selection))},
		{"Selection.rectangle offset", int(offset_of(gh.Selection, rectangle))},
		{"Selection_Format_Options size", int(size_of(gh.Selection_Format_Options))},
		{"Selection_Format_Options.selection offset", int(offset_of(gh.Selection_Format_Options, selection))},
		{"Scroll_Viewport size", int(size_of(gh.Scroll_Viewport))},
		{"Scrollbar size", int(size_of(gh.Scrollbar))},
		{"Mode_Config size", int(size_of(gh.Mode_Config))},
		{"Render_Cursor size", int(size_of(gh.Render_Cursor))},
		{"Render_Cursor.visual_style offset", int(offset_of(gh.Render_Cursor, visual_style))},
		{"Render_Colors size", int(size_of(gh.Render_Colors))},
		{"Render_Colors.palette offset", int(offset_of(gh.Render_Colors, palette))},
		{"Row_Selection size", int(size_of(gh.Row_Selection))},
		{"Mouse_Encoder_Size size", int(size_of(gh.Mouse_Encoder_Size))},
		{"Mouse_Position size", int(size_of(gh.Mouse_Position))},
		{"Key.F25 value", int(int(gh.Key.F25))},
		{"Key.Escape value", int(int(gh.Key.Escape))},
		{"Terminal_Option.Color_Palette value", int(int(gh.Terminal_Option.Color_Palette))},
		{"Terminal_Option.Color_Scheme value", int(gh.Terminal_Option.Color_Scheme)},
		{"Color_Scheme.Dark value", int(gh.Color_Scheme.Dark)},
		{"Terminal_Data.Color_Background_Default value", int(int(gh.Terminal_Data.Color_Background_Default))},
		{"Terminal_Data.Kitty_Keyboard_Flags value", int(gh.Terminal_Data.Kitty_Keyboard_Flags)},
		{"Point_Coordinate size", int(size_of(gh.Point_Coordinate))},
		{"Cell_Data.Has_Hyperlink value", int(gh.Cell_Data.Has_Hyperlink)},
		{"Grid_Row_Data.Wrap value", int(gh.Grid_Row_Data.Wrap)},
		{"Grid_Row_Data.Hyperlink value", int(gh.Grid_Row_Data.Hyperlink)},
		{"Grid_Row size", int(size_of(gh.Grid_Row))},
		{"Program_Status size", int(size_of(gh.Program_Status))},
		{"Program_Status.progress offset", int(offset_of(gh.Program_Status, progress))},
		{"Program_Status.id offset", int(offset_of(gh.Program_Status, id))},
		{"Program_Status.message offset", int(offset_of(gh.Program_Status, message))},
		{"Semantic_Prompt size", int(size_of(gh.Semantic_Prompt))},
		{"Semantic_Prompt.exit_code offset", int(offset_of(gh.Semantic_Prompt, exit_code))},
		{"Semantic_Prompt.error offset", int(offset_of(gh.Semantic_Prompt, error))},
		{"Terminal_Option.Program_Status value", int(gh.Terminal_Option.Program_Status)},
		{"Terminal_Option.Semantic_Prompt value", int(gh.Terminal_Option.Semantic_Prompt)},
		{"Program_Status_State.Clear value", int(gh.Program_Status_State.Clear)},
		{"Program_Status_Kind.Auth value", int(gh.Program_Status_Kind.Auth)},
		{"Semantic_Prompt_Kind.Prompt_Start value", int(gh.Semantic_Prompt_Kind.Prompt_Start)},
	}
	seen := 0
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		sp := strings.last_index_byte(line, ' ')
		if sp < 0 do continue
		key := line[:sp]
		c_val, _ := strconv.parse_int(line[sp + 1:])
		odin_val, ok := 0, false
		for w in want do if w.key == key do odin_val, ok = w.val, true
		testing.expectf(t, ok, "no Odin counterpart for %q", key)
		testing.expectf(t, odin_val == c_val, "%s: odin %d, C %d", key, odin_val, c_val)
		seen += 1
	}
	testing.expect_value(t, seen, len(want))
}

@(test)
terminal_roundtrip :: proc(t: ^testing.T) {
	term: gh.Terminal
	testing.expect_value(t, gh.terminal_new(nil, &term, 20, 4), gh.Result.Success)
	defer gh.terminal_free(term)

	s := "hi \x1b[1;31mred\x1b[0m 世\r\n"
	gh.terminal_vt_write(term, raw_data(s), len(s))

	rs: gh.Render_State
	testing.expect_value(t, gh.render_state_new(nil, &rs), gh.Result.Success)
	defer gh.render_state_free(rs)
	testing.expect_value(t, gh.render_state_update(rs, term), gh.Result.Success)

	colors := gh.Render_Colors{size = size_of(gh.Render_Colors)}
	testing.expect_value(t, gh.render_state_get(rs, .Colors, &colors), gh.Result.Success)
	cursor := gh.Render_Cursor{size = size_of(gh.Render_Cursor)}
	testing.expect_value(t, gh.render_state_get(rs, .Cursor, &cursor), gh.Result.Success)
	testing.expect(t, cursor.viewport_has_value)
	testing.expect_value(t, cursor.viewport_y, 1)

	it: gh.Row_Iterator
	gh.render_state_row_iterator_new(nil, &it)
	defer gh.render_state_row_iterator_free(it)
	cells: gh.Row_Cells
	gh.render_state_row_cells_new(nil, &cells)
	defer gh.render_state_row_cells_free(cells)
	gh.render_state_get(rs, .Row_Iterator, &it)
	testing.expect(t, gh.render_state_row_iterator_next(it))
	gh.render_state_row_get(it, .Cells, &cells)

	text: [dynamic]rune
	defer delete(text)
	col := 0
	for gh.render_state_row_cells_next(cells) {
		n: u32
		gh.render_state_row_cells_get(cells, .Graphemes_Len, &n)
		cp: [8]u32
		if n > 0 do gh.render_state_row_cells_get(cells, .Graphemes_Buf, &cp[0])
		append(&text, n > 0 ? rune(cp[0]) : ' ')
		if col == 3 { // 'r' of "red": bold, palette red
			st := gh.Style{size = size_of(gh.Style)}
			gh.render_state_row_cells_get(cells, .Style, &st)
			testing.expect(t, st.bold)
			testing.expect_value(t, st.fg_color.tag, gh.Style_Color_Tag.Palette)
			testing.expect_value(t, st.fg_color.value.palette, 1)
		}
		if col == 7 || col == 8 { // wide char + spacer tail
			raw: gh.Cell
			gh.render_state_row_cells_get(cells, .Raw, &raw)
			wide: gh.Cell_Wide
			gh.cell_get(raw, .Wide, &wide)
			testing.expect_value(t, wide, col == 7 ? gh.Cell_Wide.Wide : gh.Cell_Wide.Spacer_Tail)
		}
		col += 1
	}
	testing.expect_value(t, col, 20)
	got := strings.trim_right_space(utf32_to_string(text[:]))
	defer delete(got)
	testing.expect_value(t, got, "hi red 世")

	// selection over "red" -> plain text
	a, b: gh.Grid_Ref = {size = size_of(gh.Grid_Ref)}, {size = size_of(gh.Grid_Ref)}
	pa := gh.Point{tag = .Viewport}
	pa.value.coordinate = {x = 3, y = 0}
	pb := gh.Point{tag = .Viewport}
	pb.value.coordinate = {x = 5, y = 0}
	testing.expect_value(t, gh.terminal_grid_ref(term, pa, &a), gh.Result.Success)
	testing.expect_value(t, gh.terminal_grid_ref(term, pb, &b), gh.Result.Success)
	sel := gh.Selection{size = size_of(gh.Selection), start = a, end = b}
	opts := gh.Selection_Format_Options{size = size_of(gh.Selection_Format_Options), emit = .Plain, trim = true, selection = &sel}
	out: [^]u8
	out_len: uint
	testing.expect_value(t, gh.terminal_selection_format_alloc(term, nil, opts, &out, &out_len), gh.Result.Success)
	testing.expect_value(t, string(out[:out_len]), "red")
	gh.free(nil, out, out_len)
}

@(test)
encoders :: proc(t: ^testing.T) {
	term: gh.Terminal
	gh.terminal_new(nil, &term, 80, 24)
	defer gh.terminal_free(term)

	enc: gh.Key_Encoder
	gh.key_encoder_new(nil, &enc)
	defer gh.key_encoder_free(enc)
	ev: gh.Key_Event
	gh.key_event_new(nil, &ev)
	defer gh.key_event_free(ev)
	buf: [64]u8
	n: uint

	// legacy: Ctrl+C -> 0x03
	gh.key_encoder_setopt_from_terminal(enc, term)
	gh.key_event_set_action(ev, .Press)
	gh.key_event_set_key(ev, .C)
	gh.key_event_set_mods(ev, gh.MOD_CTRL)
	gh.key_event_set_unshifted_codepoint(ev, 'c')
	testing.expect_value(t, gh.key_encoder_encode(enc, ev, &buf[0], len(buf), &n), gh.Result.Success)
	testing.expect_value(t, string(buf[:n]), "\x03")

	// kitty keyboard pushed by the app (CSI > 1 u): Shift+Enter -> CSI 13;2u
	s := "\x1b[>1u"
	gh.terminal_vt_write(term, raw_data(s), len(s))
	gh.key_encoder_setopt_from_terminal(enc, term)
	gh.key_event_set_key(ev, .Enter)
	gh.key_event_set_mods(ev, gh.MOD_SHIFT)
	gh.key_event_set_unshifted_codepoint(ev, 0)
	testing.expect_value(t, gh.key_encoder_encode(enc, ev, &buf[0], len(buf), &n), gh.Result.Success)
	testing.expect_value(t, string(buf[:n]), "\x1b[13;2u")

	// Alt+Enter (pi: queue follow-up) under kitty flags -> CSI 13;3u
	gh.key_event_set_mods(ev, gh.MOD_ALT)
	testing.expect_value(t, gh.key_encoder_encode(enc, ev, &buf[0], len(buf), &n), gh.Result.Success)
	testing.expect_value(t, string(buf[:n]), "\x1b[13;3u")

	// paste: bracketed wraps, unbracketed turns \n into \r
	p := "a\nb"
	pb := transmute([]u8)strings.clone(p)
	defer delete(pb)
	testing.expect_value(t, gh.paste_encode(raw_data(pb), len(pb), true, &buf[0], len(buf), &n), gh.Result.Success)
	testing.expect_value(t, string(buf[:n]), "\x1b[200~a\nb\x1b[201~")

	// mouse: SGR wheel-up report once the app enables tracking (1000 + 1006)
	m := "\x1b[?1000h\x1b[?1006h"
	gh.terminal_vt_write(term, raw_data(m), len(m))
	menc: gh.Mouse_Encoder
	gh.mouse_encoder_new(nil, &menc)
	defer gh.mouse_encoder_free(menc)
	gh.mouse_encoder_setopt_from_terminal(menc, term)
	size := gh.Mouse_Encoder_Size{size = size_of(gh.Mouse_Encoder_Size), screen_width = 800, screen_height = 480, cell_width = 10, cell_height = 20}
	gh.mouse_encoder_setopt(menc, .Size, &size)
	mev: gh.Mouse_Event
	gh.mouse_event_new(nil, &mev)
	defer gh.mouse_event_free(mev)
	gh.mouse_event_set_action(mev, .Press)
	gh.mouse_event_set_button(mev, .Four)
	gh.mouse_event_set_position(mev, {x = 25, y = 45})
	testing.expect_value(t, gh.mouse_encoder_encode(menc, mev, &buf[0], len(buf), &n), gh.Result.Success)
	testing.expect_value(t, string(buf[:n]), "\x1b[<64;3;3M")
}

utf32_to_string :: proc(rs: []rune) -> string {
	b := strings.builder_make()
	for r in rs do strings.write_rune(&b, r)
	return strings.to_string(b)
}

// OSC 7501 (program status): the query is answered only while the callback
// is set; a report arrives decoded (msg base64), a malformed one does not.
Ps_Probe :: struct {
	reply:   [dynamic]u8,
	reports: int,
	state:   gh.Program_Status_State,
	kind:    gh.Program_Status_Kind,
	app:     string,
	msg:     string,
	id:      string,
	prompts: int,
}

@(test)
program_status_osc7501 :: proc(t: ^testing.T) {
	term: gh.Terminal
	testing.expect_value(t, gh.terminal_new(nil, &term, 40, 4), gh.Result.Success)
	defer gh.terminal_free(term)
	probe: Ps_Probe
	defer {
		delete(probe.reply)
		delete(probe.app)
		delete(probe.msg)
		delete(probe.id)
	}
	gh.terminal_set(term, .Userdata, &probe)
	write_pty :: proc "c" (gt: gh.Terminal, ud: rawptr, data: [^]u8, n: c.size_t) {
		context = runtime.default_context()
		p := (^Ps_Probe)(ud)
		append(&p.reply, ..data[:n])
	}
	on_status :: proc "c" (gt: gh.Terminal, ud: rawptr, r: ^gh.Program_Status) {
		context = runtime.default_context()
		p := (^Ps_Probe)(ud)
		p.reports += 1
		p.state, p.kind = r.state, r.kind
		delete(p.app)
		delete(p.msg)
		delete(p.id)
		p.app = strings.clone(string(r.app.ptr[:r.app.len]))
		p.msg = strings.clone(string(r.message.ptr[:r.message.len]))
		p.id = strings.clone(string(r.id.ptr[:r.id.len]))
	}
	on_prompt :: proc "c" (gt: gh.Terminal, ud: rawptr, e: ^gh.Semantic_Prompt) {
		p := (^Ps_Probe)(ud)
		if e.kind == .Prompt_Start do p.prompts += 1
	}
	gh.terminal_set(term, .Write_Pty, rawptr(write_pty))
	w :: proc(term: gh.Terminal, s: string) {gh.terminal_vt_write(term, raw_data(s), len(s))}

	// no callback: no reply
	w(term, "\x1b]7501;?\x1b\\")
	testing.expect_value(t, len(probe.reply), 0)

	gh.terminal_set(term, .Program_Status, rawptr(on_status))
	gh.terminal_set(term, .Semantic_Prompt, rawptr(on_prompt))
	w(term, "\x1b]7501;?\x1b\\")
	reply := string(probe.reply[:])
	testing.expectf(t, strings.has_prefix(reply, "\x1b]7501;?:states="), "reply %q", reply)
	testing.expect(t, strings.contains(reply, "blocked"))
	testing.expect(t, strings.contains(reply, "kinds=permission"))

	// "Apply?" in base64
	w(term, "\x1b]7501;state=blocked:kind=permission:app=claude-code:msg=QXBwbHk/\x07")
	testing.expect_value(t, probe.reports, 1)
	testing.expect_value(t, probe.state, gh.Program_Status_State.Blocked)
	testing.expect_value(t, probe.kind, gh.Program_Status_Kind.Permission)
	testing.expect_value(t, probe.app, "claude-code")
	testing.expect_value(t, probe.msg, "Apply?")

	w(term, "\x1b]7501;state=working:id=build/test\x07")
	testing.expect_value(t, probe.reports, 2)
	testing.expect_value(t, probe.id, "build/test")

	// malformed: an unknown state is dropped; bad base64 drops only the message
	w(term, "\x1b]7501;state=sleeping\x07")
	testing.expect_value(t, probe.reports, 2)
	w(term, "\x1b]7501;state=done:msg=!!!\x07")
	testing.expect_value(t, probe.reports, 3)
	testing.expect_value(t, probe.state, gh.Program_Status_State.Done)
	testing.expect_value(t, probe.msg, "")

	// RIS: a clear with an empty id
	w(term, "\x1bc")
	testing.expect_value(t, probe.reports, 4)
	testing.expect_value(t, probe.state, gh.Program_Status_State.Clear)
	testing.expect_value(t, probe.id, "")

	// OSC 133 A: a new prompt
	w(term, "\x1b]133;A\x07")
	testing.expect_value(t, probe.prompts, 1)
}
