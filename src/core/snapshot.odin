package core

// Terminal snapshots (design §5.5, §7.2): what the core sends a window on
// attach, and what a core hands its successor, to rebuild a terminal exactly
// at a byte offset of its PTY stream.
//
// A snapshot is [meta_len u32 LE][meta JSON][body]. The body is GHOSTSNP
// (libghostty-vt's snapshot codec: both screens, scrollback, cursor and saved
// cursor, modes, margins, tab stops, charsets, colours, title, the unfinished
// escape...), or, when the two sides share no GHOSTSNP version, the VT
// formatter's output, marked inexact: it loses the primary screen while the
// alt screen is up, the DECSC saved cursor, per-cell DECSCA and OSC 133 marks
// (S1, branch spike/vt-snapshot).
//
// Exactness is checked with screen_hash, never by comparing snapshot bytes:
// re-encoding a decoded terminal can give other bytes for the same screen.
// Pure: no app state; the callers attach the result with term_adopt_gt.

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import gh "../ghostty"
import hw "../holderwire"

SNAPSHOT_GHOSTSNP :: "ghostsnp/1"
SNAPSHOT_VT :: "vt"
// What this side decodes, best first: the hello's `snapshot` list (§5.2).
SNAPSHOT_FORMATS := [?]string{SNAPSHOT_GHOSTSNP, SNAPSHOT_VT}

// The meta is small; anything larger is refused before it is parsed (see
// holderwire.json_shape_ok for why the parser needs guarding).
SNAPSHOT_META_MAX :: 64 * 1024

// The largest grid a snapshot (and the holder wire) carries; term_set_rect
// never makes a bigger one, so our own snapshots always decode.
MAX_TERM_COLS :: hw.MAX_COLS
MAX_TERM_ROWS :: hw.MAX_ROWS

// The grid a GHOSTSNP body declares, read before the codec allocates it: the
// TERMINAL record comes first, after the 10-byte envelope and a 10-byte
// record header (tag u16 = 1, len u32, CRC32C u32), and starts with columns
// u16 and rows u16 (ghostty src/terminal/snapshot/terminal.zig). This bounds
// the screen only: history pages declare their own sizes, so the real control
// against a hostile snapshot is the MAC check (PR B) before snapshot_decode.
snapshot_ghostsnp_grid :: proc(body: []u8) -> (ok: bool, grid: [2]u16) {
	if len(body) < 24 || string(body[:8]) != "GHOSTSNP" do return false, {}
	tag, _ := endian.get_u16(body[10:12], .Little)
	if tag != 1 do return false, {}
	grid[0], _ = endian.get_u16(body[20:22], .Little)
	grid[1], _ = endian.get_u16(body[22:24], .Little)
	return true, grid
}

// Beside the terminal: what Deckhand keeps about the stream. Grow-only JSON;
// unknown fields are ignored. (OSC 7501 status joins in M1 PR B, with the
// holder that needs it.) After decoding, `format` is always one of the
// SNAPSHOT_* constants, so the meta holds no allocation.
Snapshot_Meta :: struct {
	format:      string, // SNAPSHOT_GHOSTSNP or SNAPSHOT_VT
	offset:      u64, // the PTY stream offset the snapshot is at
	cols:        i64,
	rows:        i64,
	xpixel:      i64,
	ypixel:      i64,
	exit_code:   i64,
	exit_signal: i64,
	exited:      i64, // 1 once the process has exited
	inexact:     bool, // the VT fallback (or a lost continuation): not a byte-exact rebuild
}

Snapshot_Error :: enum {
	None,
	No_Common_Format, // the peer decodes neither format
	Unfinished, // mid-sequence beyond the continuation limit: retry after ground (or allow the fallback)
	Encode_Failed,
	Bad_Snapshot, // truncated, corrupt, trailing bytes, or bad meta
	Unknown_Format,
}

// The best format both sides decode ("" if none).
snapshot_pick_format :: proc(peer: []string) -> string {
	for ours in SNAPSHOT_FORMATS do for p in peer do if p == ours do return ours
	return ""
}

// Encodes gt for a peer that decodes `peer_formats`. With `fallback_ok` (a
// handover, §7.2), a terminal GHOSTSNP can't encode yet (an unfinished
// sequence over the limit) is sent as VT, inexact; without it the caller
// retries after the next ground state.
snapshot_encode :: proc(gt: gh.Terminal, meta: Snapshot_Meta, peer_formats: []string, fallback_ok := false, allocator := context.allocator) -> (out: []u8, used: Snapshot_Meta, err: Snapshot_Error) {
	used = meta
	format := snapshot_pick_format(peer_formats)
	if format == "" do return nil, used, .No_Common_Format
	cols, rows: u16
	gh.terminal_get(gt, .Cols, &cols)
	gh.terminal_get(gt, .Rows, &rows)
	used.cols, used.rows = i64(cols), i64(rows)
	body: []u8
	if format == SNAPSHOT_GHOSTSNP {
		p: [^]u8
		n: c.size_t
		r := gh.snapshot_encode_alloc(gt, nil, &p, &n)
		if r == .Success {
			used.format, used.inexact = SNAPSHOT_GHOSTSNP, false
			out = snapshot_pack(used, p[:n], allocator)
			gh.free(nil, p, n)
			return out, used, .None
		}
		if r != .Invalid_Value do return nil, used, .Encode_Failed
		vt_ok := false
		for f in peer_formats do if f == SNAPSHOT_VT do vt_ok = true
		if !fallback_ok || !vt_ok do return nil, used, .Unfinished
	}
	cont_ok: bool
	body, cont_ok = snapshot_vt_body(gt, context.temp_allocator)
	used.format, used.inexact = SNAPSHOT_VT, true
	_ = cont_ok // VT is inexact either way
	return snapshot_pack(used, body, allocator), used, .None
}

// The VT fallback: the formatter with every extra (palette, modes, margins,
// tab stops, pwd, keyboard modes; cursor, pen, open link, DECSCA pen, kitty
// flags, charsets), unwrapped so the receiver's own wrapping restores soft
// wraps; then what the formatter omits (title, OSC 10/11/12, cursor shape);
// then the unfinished escape, false if that was unavailable.
snapshot_vt_body :: proc(gt: gh.Terminal, allocator := context.allocator) -> (body: []u8, cont_ok: bool) {
	sb := strings.builder_make(allocator)
	opts := gh.Formatter_Terminal_Options {
		size = size_of(gh.Formatter_Terminal_Options),
		emit = .VT,
		unwrap = true,
		trim = false,
	}
	opts.extra = {size = size_of(gh.Formatter_Terminal_Extra), palette = true, modes = true, scrolling_region = true, tabstops = true, pwd = true, keyboard = true}
	opts.extra.screen = {size = size_of(gh.Formatter_Screen_Extra), cursor = true, style = true, hyperlink = true, protection = true, kitty_keyboard = true, charsets = true}
	f: gh.Formatter
	if gh.formatter_terminal_new(nil, &f, gt, opts) == .Success {
		p: [^]u8
		n: c.size_t
		if gh.formatter_format_alloc(f, nil, &p, &n) == .Success && n > 0 {
			strings.write_bytes(&sb, p[:n])
			gh.free(nil, p, n)
		}
		gh.formatter_free(f)
	}
	if title := gt_string(gt, .Title); title != "" do fmt.sbprintf(&sb, "\x1b]2;%s\x1b\\", title)
	osc := [?]struct {
		data: gh.Terminal_Data,
		num:  int,
	}{{.Color_Foreground, 10}, {.Color_Background, 11}, {.Color_Cursor, 12}}
	for o in osc {
		rgb: gh.Color_Rgb
		if gh.terminal_get(gt, o.data, &rgb) == .Success do fmt.sbprintf(&sb, "\x1b]%d;rgb:%02x/%02x/%02x\x1b\\", o.num, rgb.r, rgb.g, rgb.b)
	}
	cur, _ := gt_cursor_shape(gt)
	shape := 1
	switch cur.visual_style {
	case .Block, .Block_Hollow: shape = 1
	case .Underline: shape = 3
	case .Bar: shape = 5
	}
	if !cur.blinking do shape += 1
	fmt.sbprintf(&sb, "\x1b[%d q", shape)
	p: [^]u8
	n: c.size_t
	if gh.terminal_continuation_alloc(gt, nil, &p, &n) == .Success {
		cont_ok = true
		if n > 0 {strings.write_bytes(&sb, p[:n]); gh.free(nil, p, n)}
	}
	return sb.buf[:], cont_ok
}

@(private)
snapshot_pack :: proc(meta: Snapshot_Meta, body: []u8, allocator := context.allocator) -> []u8 {
	mj, _ := json.marshal(meta, {}, context.temp_allocator)
	out := make([]u8, 4 + len(mj) + len(body), allocator)
	endian.put_u32(out[:4], .Little, u32(len(mj)))
	copy(out[4:], mj)
	copy(out[4 + len(mj):], body)
	return out
}

// Reads the meta of a snapshot and returns its body (borrowed).
snapshot_unpack :: proc(blob: []u8) -> (meta: Snapshot_Meta, body: []u8, err: Snapshot_Error) {
	if len(blob) < 4 do return {}, nil, .Bad_Snapshot
	n, _ := endian.get_u32(blob[:4], .Little)
	if u64(n) > u64(len(blob) - 4) || n > SNAPSHOT_META_MAX do return {}, nil, .Bad_Snapshot
	if !hw.json_shape_ok(blob[4:4 + n], 8, 256) do return {}, nil, .Bad_Snapshot
	v, perr := json.parse(blob[4:4 + n], .JSON, true, context.temp_allocator)
	if perr != nil do return {}, nil, .Bad_Snapshot
	if _, ok := v.(json.Object); !ok do return {}, nil, .Bad_Snapshot
	if json.unmarshal(blob[4:4 + n], &meta, .JSON, context.temp_allocator) != nil do return {}, nil, .Bad_Snapshot
	if !hw.size_ok(meta.cols, meta.rows, meta.xpixel, meta.ypixel) do return {}, nil, .Bad_Snapshot
	// the parsed string lives in temp memory: swap in the constant
	switch meta.format {
	case SNAPSHOT_GHOSTSNP: meta.format = SNAPSHOT_GHOSTSNP
	case SNAPSHOT_VT: meta.format = SNAPSHOT_VT
	case: meta.format = ""
	}
	return meta, blob[4 + n:], .None
}

// Rebuilds a terminal (caller-owned; attach with term_adopt_gt) from a
// snapshot. The terminal tracks its continuation, like every terminal.
snapshot_decode :: proc(blob: []u8) -> (gt: gh.Terminal, meta: Snapshot_Meta, err: Snapshot_Error) {
	body: []u8
	meta, body, err = snapshot_unpack(blob)
	if err != .None do return
	switch meta.format {
	case SNAPSHOT_GHOSTSNP:
		ok, grid := snapshot_ghostsnp_grid(body)
		if !ok || i64(grid[0]) != meta.cols || i64(grid[1]) != meta.rows do return nil, meta, .Bad_Snapshot
		d: gh.Snapshot_Decoder
		if gh.snapshot_decoder_new_buf(nil, &d, raw_data(body), c.size_t(len(body))) != .Success do return nil, meta, .Bad_Snapshot
		defer gh.snapshot_decoder_free(d)
		limit := TERM_CONTINUATION_MAX
		retain, compress := true, true
		gh.snapshot_decoder_set(d, .Max_Continuation_Bytes, &limit)
		gh.snapshot_decoder_set(d, .Retain_Continuation, &retain)
		gh.snapshot_decoder_set(d, .Compress_History, &compress)
		if gh.snapshot_decoder_decode(d, &gt) != .Success do return nil, meta, .Bad_Snapshot
		used: c.size_t
		cols, rows: u16
		gh.terminal_get(gt, .Cols, &cols)
		gh.terminal_get(gt, .Rows, &rows)
		if gh.snapshot_decoder_get(d, .Source_Offset, &used) != .Success || int(used) != len(body) || i64(cols) != meta.cols || i64(rows) != meta.rows {
			gh.terminal_free(gt)
			return nil, meta, .Bad_Snapshot
		}
	case SNAPSHOT_VT:
		if gh.terminal_new(nil, &gt, u16(meta.cols), u16(meta.rows)) != .Success do return nil, meta, .Bad_Snapshot
		sb := uint(TERM_SCROLLBACK_MAX)
		gh.terminal_set(gt, .Scrollback_Max_Bytes, &sb)
		limit := TERM_CONTINUATION_MAX
		gh.terminal_set(gt, .Continuation_Max_Bytes, &limit)
		if len(body) > 0 do gh.terminal_vt_write(gt, raw_data(body), len(body))
	case:
		return nil, meta, .Unknown_Format
	}
	return gt, meta, .None
}

// ---- the screen hash ----

@(private = "file")
SCREEN_MODES_ANSI := [?]u16{2, 4, 12, 20}
@(private = "file")
SCREEN_MODES_DEC := [?]u16{1, 3, 4, 5, 6, 7, 8, 9, 12, 25, 40, 45, 47, 66, 67, 69, 1000, 1002, 1003, 1004, 1005, 1006, 1007, 1015, 1016, 1035, 1036, 1039, 1045, 1047, 1048, 1049, 2004, 2026, 2027, 2031, 2033, 2048, 5522}

// FNV-1a 64 of screen_dump. `both` is false when the alt screen is up and the
// primary couldn't be read (see screen_dump).
//
// What it does not prove. The cursor shape and the inactive screen are read
// from a GHOSTSNP clone on each side, so between a terminal and one decoded
// from its GHOSTSNP snapshot those two facts are checked only as far as the
// codec carries them to itself. And it leaves out state no getter exposes:
// the DECSC saved cursor, the scroll and left/right margins, tab stops,
// charsets, the kitty keyboard stack (only the current flags are in) and
// modifyOtherKeys. To check those, compare against a reference terminal fed
// the same bytes with screen_equal_probed, which writes SCREEN_PROBES into
// both so that hidden state shows on screen.
//
// last_rows > 0: only that many rows of each screen, from the end (the screen and its newest
// history), and not how many rows there are in all: the window's per-step check
// (term_view_stream.odin), where all of a big scrollback would take seconds, and where the two
// copies may keep a different number of the oldest rows once the scrollback is full (the limit
// is in bytes of page memory, and a terminal decoded from a snapshot lays its pages out
// differently from one that parsed every byte: rows are dropped a page at a time).
screen_hash :: proc(gt: gh.Terminal, last_rows := 0) -> (h: u64, both: bool) {
	sb := strings.builder_make(context.temp_allocator)
	both = screen_dump(gt, &sb, last_rows)
	h = 0xcbf29ce484222325
	for b in sb.buf[:] {h = (h ~ u64(b)) * 0x100000001b3}
	return
}

// Sequences that make hidden state visible: the pen and charset (P q x),
// tab stops, the saved cursor (ESC 8), the scroll region (LFs at the bottom,
// RI, SU/SD), pending wrap, then the other screen (leaving the alt screen).
SCREEN_PROBES := [?]string{"Pqx\tT\tT\x1b8R\x1b[999;1HA\n\n\nB\x1bMC\x1b[1;1HD\x1b[5SE\x1b[2TF", "\x1b[?1049l\x1b[?47lQ\x1b8S\x1b[999;999HZ"}

// True if a and b dump the same now and after each of SCREEN_PROBES. It writes
// the probes into both, so pass terminals you can spend (clones: gt_clone).
// For scenes: b is the terminal under test (a restored or attached one), a a
// reference fed the same bytes.
screen_equal_probed :: proc(a, b: gh.Terminal) -> bool {
	da := strings.builder_make(context.temp_allocator)
	db := strings.builder_make(context.temp_allocator)
	screen_dump(a, &da)
	screen_dump(b, &db)
	if strings.to_string(da) != strings.to_string(db) do return false
	for p in SCREEN_PROBES {
		gh.terminal_vt_write(a, raw_data(p), len(p))
		gh.terminal_vt_write(b, raw_data(p), len(p))
		strings.builder_reset(&da)
		strings.builder_reset(&db)
		screen_dump(a, &da)
		screen_dump(b, &db)
		if strings.to_string(da) != strings.to_string(db) do return false
	}
	return true
}

// One line per fact: size, cursor (position, pending wrap, visibility, shape),
// pen, every mode, keyboard and mouse state, title, pwd, colours and palette;
// then every row of the active screen and its scrollback (wrap flags, OSC 133
// marks, and per cell the grapheme, width, style, link, DECSCA and semantic
// content). With the alt screen up, the primary's rows follow too, read from
// a GHOSTSNP clone switched back (the API reads only the active screen).
//
// Everything is read from gt itself except two things the API only gives
// another way, read from a GHOSTSNP clone: the cursor shape (only a render
// state has it, and updating one would take gt's dirty flags from the app's
// renderer) and the inactive primary screen. Without a clone (an unfinished
// sequence over the limit) those are left out and `both` is false.
screen_dump :: proc(gt: gh.Terminal, sb: ^strings.Builder, last_rows := 0) -> (both: bool) {
	screen: gh.Terminal_Screen
	gh.terminal_get(gt, .Active_Screen, &screen)
	clone, cloned := gt_clone(gt)
	defer if cloned do gh.terminal_free(clone)
	dump_state(gt, cloned ? clone : nil, sb, totals = last_rows <= 0)
	dump_rows(gt, sb, last_rows)
	if !cloned do return false
	if screen != .Alternate do return true
	for leave in ([?]string{"\x1b[?1049l", "\x1b[?1047l", "\x1b[?47l"}) {
		gh.terminal_vt_write(clone, raw_data(leave), len(leave))
		gh.terminal_get(clone, .Active_Screen, &screen)
		if screen == .Primary do break
	}
	if screen != .Primary do return false
	strings.write_string(sb, "primary\n")
	dump_rows(clone, sb, last_rows)
	return true
}

@(private = "file")
dump_state :: proc(gt, clone: gh.Terminal, sb: ^strings.Builder, totals := true) {
	cols, rows: u16
	total, history: c.size_t
	screen: gh.Terminal_Screen
	gh.terminal_get(gt, .Cols, &cols)
	gh.terminal_get(gt, .Rows, &rows)
	gh.terminal_get(gt, .Total_Rows, &total)
	gh.terminal_get(gt, .Scrollback_Rows, &history)
	gh.terminal_get(gt, .Active_Screen, &screen)
	if totals do fmt.sbprintf(sb, "size %dx%d total %d history %d screen %v\n", cols, rows, total, history, screen)
	else do fmt.sbprintf(sb, "size %dx%d screen %v\n", cols, rows, screen) // the newest rows only: how deep the scrollback goes is left out
	cx, cy: u16
	pending, visible: bool
	gh.terminal_get(gt, .Cursor_X, &cx)
	gh.terminal_get(gt, .Cursor_Y, &cy)
	gh.terminal_get(gt, .Cursor_Pending_Wrap, &pending)
	gh.terminal_get(gt, .Cursor_Visible, &visible)
	fmt.sbprintf(sb, "cursor %d,%d wrap %v visible %v", cx, cy, pending, visible)
	if clone != nil {
		cur := gt_render_cursor(clone)
		fmt.sbprintf(sb, " shape %v blink %v", cur.visual_style, cur.blinking)
	}
	strings.write_byte(sb, '\n')
	pen := gh.Style{size = size_of(gh.Style)}
	gh.terminal_get(gt, .Cursor_Style, &pen)
	strings.write_string(sb, "pen ")
	dump_style(sb, pen)
	strings.write_string(sb, "\nmodes")
	for m in SCREEN_MODES_ANSI {
		mc := gh.Mode_Config{mode = m | 0x8000}
		ok := gh.terminal_get(gt, .Mode, &mc) == .Success
		fmt.sbprintf(sb, " %d=%s", m, ok ? (mc.value ? "1" : "0") : "?")
	}
	for m in SCREEN_MODES_DEC {
		mc := gh.Mode_Config{mode = gh.mode_dec(m)}
		ok := gh.terminal_get(gt, .Mode, &mc) == .Success
		fmt.sbprintf(sb, " ?%d=%s", m, ok ? (mc.value ? "1" : "0") : "?")
	}
	kitty: u8
	mouse: bool
	gh.terminal_get(gt, .Kitty_Keyboard_Flags, &kitty)
	gh.terminal_get(gt, .Mouse_Tracking, &mouse)
	fmt.sbprintf(sb, "\nkitty %d mouse %v\ntitle %q\npwd %q\ncolors", kitty, mouse, gt_string(gt, .Title), gt_string(gt, .Pwd))
	for d in ([?]gh.Terminal_Data{.Color_Foreground, .Color_Background, .Color_Cursor}) {
		rgb: gh.Color_Rgb
		if gh.terminal_get(gt, d, &rgb) == .Success do fmt.sbprintf(sb, " %02x%02x%02x", rgb.r, rgb.g, rgb.b)
		else do strings.write_string(sb, " -")
	}
	pal: [256]gh.Color_Rgb
	gh.terminal_get(gt, .Color_Palette, &pal)
	strings.write_string(sb, " palette ")
	for p in pal do fmt.sbprintf(sb, "%02x%02x%02x", p.r, p.g, p.b)
	strings.write_byte(sb, '\n')
}

@(private = "file")
dump_rows :: proc(gt: gh.Terminal, sb: ^strings.Builder, last_rows := 0) {
	cols: u16
	total: c.size_t
	gh.terminal_get(gt, .Cols, &cols)
	gh.terminal_get(gt, .Total_Rows, &total)
	graphemes: [64]u32
	uri: [2048]u8
	first := last_rows > 0 ? max(int(total) - last_rows, 0) : 0
	for y in first ..< int(total) {
		ref := gh.Grid_Ref{size = size_of(gh.Grid_Ref)}
		pt := gh.Point{tag = .Screen}
		pt.value.coordinate = {0, u32(y)}
		if gh.terminal_grid_ref(gt, pt, &ref) != .Success {fmt.sbprintf(sb, "%d ?\n", y); continue}
		row: gh.Grid_Row
		gh.grid_ref_row(&ref, &row)
		wrap, cont: bool
		mark: c.int
		gh.row_get(row, .Wrap, &wrap)
		gh.row_get(row, .Wrap_Continuation, &cont)
		gh.row_get(row, .Semantic_Prompt, &mark)
		fmt.sbprintf(sb, "%d%s%s m%d|", y - first, wrap ? "W" : "", cont ? "C" : "", mark) // from the first row dumped
		last := strings.builder_make(context.temp_allocator)
		for x in 0 ..< int(cols) {
			pt.value.coordinate = {u16(x), u32(y)}
			if gh.terminal_grid_ref(gt, pt, &ref) != .Success {strings.write_byte(sb, '?'); continue}
			st := gh.Style{size = size_of(gh.Style)}
			gh.grid_ref_style(&ref, &st)
			cur := strings.builder_make(context.temp_allocator)
			dump_style(&cur, st)
			if strings.to_string(cur) != strings.to_string(last) { // a style run starts
				fmt.sbprintf(sb, "[%s]", strings.to_string(cur))
				strings.builder_reset(&last)
				strings.write_string(&last, strings.to_string(cur))
			}
			cell: gh.Cell
			gh.grid_ref_cell(&ref, &cell)
			n: c.size_t
			gh.grid_ref_graphemes(&ref, &graphemes[0], len(graphemes), &n)
			if n == 0 do strings.write_byte(sb, ' ')
			for i in 0 ..< min(int(n), len(graphemes)) do strings.write_rune(sb, rune(graphemes[i]))
			wide: gh.Cell_Wide
			link, protected: bool
			sem: gh.Cell_Semantic_Content
			gh.cell_get(cell, .Wide, &wide)
			gh.cell_get(cell, .Has_Hyperlink, &link)
			gh.cell_get(cell, .Protected, &protected)
			gh.cell_get(cell, .Semantic_Content, &sem)
			if wide != .Narrow do fmt.sbprintf(sb, "<w%d>", int(wide))
			if protected do strings.write_string(sb, "<P>")
			if sem != .Output do fmt.sbprintf(sb, "<s%d>", int(sem))
			if link {
				un: c.size_t
				gh.grid_ref_hyperlink_uri(&ref, &uri[0], len(uri), &un)
				fmt.sbprintf(sb, "<L%s>", string(uri[:min(int(un), len(uri))]))
			}
		}
		strings.write_byte(sb, '\n')
	}
}

@(private = "file")
dump_style :: proc(sb: ^strings.Builder, st: gh.Style) {
	for col in ([?]gh.Style_Color{st.fg_color, st.bg_color, st.underline_color}) {
		switch col.tag {
		case .None: strings.write_byte(sb, '-')
		case .Palette: fmt.sbprintf(sb, "p%d", col.value.palette)
		case .Rgb: fmt.sbprintf(sb, "#%02x%02x%02x", col.value.rgb.r, col.value.rgb.g, col.value.rgb.b)
		}
		strings.write_byte(sb, '/')
	}
	flags := [?]bool{st.bold, st.italic, st.faint, st.blink, st.inverse, st.invisible, st.strikethrough, st.overline}
	letters := "biflrxso"
	for f, i in flags do strings.write_byte(sb, f ? letters[i] : '.')
	fmt.sbprintf(sb, "u%d", st.underline)
}

gt_string :: proc(gt: gh.Terminal, data: gh.Terminal_Data) -> string {
	s: gh.String
	if gh.terminal_get(gt, data, &s) != .Success || s.len == 0 do return ""
	return strings.clone(string(s.ptr[:s.len]), context.temp_allocator)
}

// A GHOSTSNP copy of gt (caller frees). False while an unfinished sequence
// is over the continuation limit.
gt_clone :: proc(gt: gh.Terminal) -> (clone: gh.Terminal, ok: bool) {
	p: [^]u8
	n: c.size_t
	if gh.snapshot_encode_alloc(gt, nil, &p, &n) != .Success do return nil, false
	defer gh.free(nil, p, n)
	d: gh.Snapshot_Decoder
	if gh.snapshot_decoder_new_buf(nil, &d, p, n) != .Success do return nil, false
	defer gh.snapshot_decoder_free(d)
	if gh.snapshot_decoder_decode(d, &clone) != .Success do return nil, false
	return clone, true
}

// The cursor's shape and blink, from a clone's render state (never gt's own:
// see screen_dump).
@(private = "file")
gt_cursor_shape :: proc(gt: gh.Terminal) -> (cur: gh.Render_Cursor, ok: bool) {
	clone: gh.Terminal
	clone, ok = gt_clone(gt)
	if !ok do return {visual_style = .Block, blinking = true}, false
	defer gh.terminal_free(clone)
	return gt_render_cursor(clone), true
}

@(private = "file")
gt_render_cursor :: proc(gt: gh.Terminal) -> gh.Render_Cursor {
	rs: gh.Render_State
	cur := gh.Render_Cursor{size = size_of(gh.Render_Cursor)}
	if gh.render_state_new(nil, &rs) != .Success do return cur
	defer gh.render_state_free(rs)
	gh.render_state_update(rs, gt)
	gh.render_state_get(rs, .Cursor, &cur)
	return cur
}
