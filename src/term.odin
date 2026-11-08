package main

// Terminal pane: a child process on our own PTY, its output parsed by
// libghostty-vt, drawn cell by cell from the render state. Keyboard, mouse
// and paste input go through libghostty-vt's encoders so the bytes match
// what the app asked for (legacy, kitty keyboard, SGR mouse, bracketed paste).

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import "core:unicode/utf8"
import gh "ghostty"
import sapp "../vendor/sokol-odin/sokol/app"

OPTION_AS_ALT :: gh.Option_As_Alt.True // macOS: Option+key sends Alt (pi's Alt+Enter)
READ_BUDGET :: 4 * 1024 * 1024 // max PTY bytes parsed per frame
EXIT_REAP_WAIT :: time.Second // after a child's output ended, how long it may take to exit

Term :: struct {
	gt:           gh.Terminal,
	rs:           gh.Render_State,
	it:           gh.Row_Iterator,
	cells:        gh.Row_Cells,
	kenc:         gh.Key_Encoder,
	kev:          gh.Key_Event,
	menc:         gh.Mouse_Encoder,
	mev:          gh.Mouse_Event,
	pty:          Pty,
	reader:       Reader,
	running:      bool,
	exit:         Exit_Info, // once it exited: how (waitpid)
	eof_at:       time.Tick, // its output ended; waiting to reap it (EXIT_REAP_WAIT)
	hung_pid:     i32, // not reaped by then: hung up on, maybe still dying (a restart waits for it)
	cols, rows:   u16,
	x, y, w, h:   f32, // pane rect in framebuffer px
	// input state
	pending_key:  gh.Key, // KEY_DOWN deferred to the CHAR event that follows
	pending_mods: gh.Mods,
	pending_cp:   rune,
	char_handled: bool, // KEY_DOWN already sent the key: drop its CHAR events
	surrogate:    u32,
	selecting:    bool,
	// a drag's anchor and what its press selected (word or line: lo, hi),
	// tracked by libghostty so they stay on their text through scrolling
	// and scrollback trims; only while a drag is on
	sel_refs:     [3]gh.Tracked_Grid_Ref,
	sel_unit:     int, // 1 cells, 2 words, 3 lines (click count of the press)
	drag_at:      [2]f32, // the pointer during a selection drag (auto-scroll)
	drag_scrolled: time.Tick, // last auto-scroll step
	cursor_px:    [2]f32, // cursor cell's top-left as last drawn (input method anchor)
	mouse_down:   bool,
	mouse_button: gh.Mouse_Button, // the press reported to the app (its drags carry it)
	mouse_cell:   [2]i32,
	scroll_acc:   f32,
	focused:      bool,
	// set when something visible changed; the frame loop redraws then
	changed:      bool,
	drawn_selected: int, // selected cells in the last drawn frame (test mode reads it)
	bytes_in:     int, // stats
	last_output:  time.Tick, // last PTY output (the "running" placeholder, ui.odin)
	resized:      time.Tick, // last grid resize (throttled while a divider is dragged)
	// the link under the pointer while ⌘ is held (term_links.odin)
	link:         Term_Link, // url owned
	link_on:      bool,
	link_at:      [2]f32, // the pointer when it was looked up
	link_key:     Link_Key, // what that lookup depended on
	link_scanned: bool, // link_key is current
	link_scans:   int, // lookups made (tests)
	// what the program reports over OSC 7501 (agent_status.odin); its summary goes to the tab
	prog:         Prog_Records,
	cont_fed:     int, // bytes fed since the continuation buffer was last trimmed
	// a terminal adopted from the session holder (holder_adopt.odin)
	inexact:      bool, // not rebuilt byte-exactly (no snapshot, or the holder's tail had a gap)
	holder_lost:  bool, // its process ran in a holder that went away
	holder_away:  u32, // that holder still runs (lost, not gone): its terminal id, the process runs on there
	mute_replies: bool, // feeding replayed bytes: query replies are dropped (§7.2 P4)
	replies_dropped: int, // how many (tests)
}

// Pixels between the pane edge and the cell grid.
term_pad :: proc() -> f32 {return f32(TERM_PAD) * app.dpi}

// Default fg/bg/cursor/palette from the active look (theme.odin). Programs
// that set their own colours (OSC 4/10/11) keep them.
term_apply_theme :: proc(t: ^Term) {
	th := theme()
	fg := gh.Color_Rgb{th.term_fg.r, th.term_fg.g, th.term_fg.b}
	bg := gh.Color_Rgb{th.term_bg.r, th.term_bg.g, th.term_bg.b}
	cc := gh.Color_Rgb{th.term_cursor.r, th.term_cursor.g, th.term_cursor.b}
	pal := theme_palette(th)
	gh.terminal_set(t.gt, .Color_Foreground, &fg)
	gh.terminal_set(t.gt, .Color_Background, &bg)
	gh.terminal_set(t.gt, .Color_Cursor, &cc)
	gh.terminal_set(t.gt, .Color_Palette, &pal)
	t.changed = true
	term_report_color_scheme(t)
}

// The terminal's light/dark, for CSI ? 996 n and mode 2031 reports.
term_color_scheme :: proc() -> gh.Color_Scheme {return theme_is_light() ? .Light : .Dark}

// The default colours changed (look or appearance). An app that turned on
// mode 2031 (pi does, while its theme follows the terminal) gets the
// colour-scheme report CSI ? 997 ; 1|2 n, as Ghostty sends it on a
// light/dark switch; pi then queries the colours again (OSC 10/11/4), which
// libghostty-vt answers from the new defaults. Sent on a look change too
// (same scheme, new colours): pi re-queries on any report.
term_report_color_scheme :: proc(t: ^Term) {
	if !t.running || !mode_on(t, 2031) do return
	buf: [16]u8
	n: c.size_t
	if gh.color_scheme_report_encode(term_color_scheme(), &buf[0], len(buf), &n) == .Success do pty_write(&t.pty, buf[:n])
}

// Answers CSI ? 996 n (an app asking whether the terminal is light or dark).
on_color_scheme :: proc "c" (gt: gh.Terminal, userdata: rawptr, out: ^gh.Color_Scheme) -> bool {
	context = app_context
	out^ = term_color_scheme()
	return true
}

// The unfinished escape (or UTF-8) suffix every terminal keeps, so it can be
// snapshotted at any byte offset (snapshot.odin, design §5.5). Sized to the
// largest sequence the parser keeps whole, an OSC (8 MiB: osc.zig
// MAX_ALLOCATING_BUF), with room for its introducer. A longer one (only an
// unchunked kitty APC can be; clients send 4 KiB chunks) makes snapshots fail
// until it ends. The suffix costs memory only while a sequence is open, but
// the library keeps the buffer's high-water capacity, so term_pump trims it
// (term_continuation_trim).
TERM_CONTINUATION_MAX :: c.size_t(9 * 1024 * 1024)
TERM_SCROLLBACK_MAX :: 20 * 1024 * 1024
// trim the continuation buffer at most once per this much output
CONT_TRIM_EVERY :: 1024 * 1024

// A fresh libghostty terminal for t: Deckhand's defaults (scrollback, mode
// 2027), then term_attach_gt.
term_new_gt :: proc(t: ^Term) -> bool {
	if gh.terminal_new(nil, &t.gt, t.cols, t.rows) != .Success do return false
	max_bytes := uint(TERM_SCROLLBACK_MAX)
	gh.terminal_set(t.gt, .Scrollback_Max_Bytes, &max_bytes)
	grapheme_clusters(t)
	term_attach_gt(t)
	return true
}

// What Deckhand hangs on a terminal, which a snapshot does not carry: the
// callbacks (query replies, colour scheme, OSC 7501/133), continuation
// tracking, and the theme's default colours (programs' own colours stay).
// Run on every new terminal and on one decoded from a snapshot (term_adopt_gt).
term_attach_gt :: proc(t: ^Term) {
	gh.terminal_set(t.gt, .Userdata, t)
	gh.terminal_set(t.gt, .Write_Pty, rawptr(on_write_pty))
	gh.terminal_set(t.gt, .Color_Scheme, rawptr(on_color_scheme))
	term_status_register(t) // OSC 7501 and OSC 133 (agent_status.odin)
	cont := TERM_CONTINUATION_MAX
	gh.terminal_set(t.gt, .Continuation_Max_Bytes, &cont)
	t.cont_fed = 0
	term_apply_theme(t)
}

// Replaces t's terminal with gt (decoded from a snapshot; t takes ownership)
// and re-attaches Deckhand's callbacks, scrollback limit, cell pixel size and
// theme, as term_start sets them. Modes and grapheme clustering come from the
// snapshot.
term_adopt_gt :: proc(t: ^Term, gt: gh.Terminal) {
	term_cancel_drag(t) // its tracked ends belong to the old terminal
	if t.gt != nil do gh.terminal_free(t.gt)
	t.gt = gt
	gh.terminal_get(gt, .Cols, &t.cols)
	gh.terminal_get(gt, .Rows, &t.rows)
	max_bytes := uint(TERM_SCROLLBACK_MAX)
	gh.terminal_set(t.gt, .Scrollback_Max_Bytes, &max_bytes)
	gh.terminal_resize(t.gt, t.cols, t.rows, u32(font.cell_w), u32(font.cell_h))
	term_attach_gt(t)
	t.changed = true
}

// The continuation buffer keeps the capacity of the longest sequence it held
// (a big OSC 52 paste: tens of MiB per terminal, measured). Re-arming tracking
// at ground frees it; nothing is pending then, so nothing is lost.
term_continuation_trim :: proc(gt: gh.Terminal) -> bool {
	ground: bool
	if gh.terminal_get(gt, .Vt_Ground, &ground) != .Success || !ground do return false
	off: c.size_t = 0
	gh.terminal_set(gt, .Continuation_Max_Bytes, &off)
	cont := TERM_CONTINUATION_MAX
	gh.terminal_set(gt, .Continuation_Max_Bytes, &cont)
	return true
}

term_init :: proc(t: ^Term, cols, rows: u16) -> bool {
	t.cols, t.rows = cols, rows
	if !term_new_gt(t) do return false
	gh.render_state_new(nil, &t.rs)
	gh.render_state_row_iterator_new(nil, &t.it)
	gh.render_state_row_cells_new(nil, &t.cells)
	gh.key_encoder_new(nil, &t.kenc)
	gh.key_event_new(nil, &t.kev)
	gh.mouse_encoder_new(nil, &t.menc)
	gh.mouse_event_new(nil, &t.mev)
	t.pty.fd = -1
	t.focused = true
	return true
}

// Mode 2027 on, as Ghostty does by default: emoji ZWJ sequences, flags,
// skin tones and VS16 presentation take one (wide) cell with the whole
// grapheme in it, which the text layer then shapes as one run.
grapheme_clusters :: proc(t: ^Term) {
	mc := gh.Mode_Config{mode = gh.mode_dec(2027), value = true}
	gh.terminal_set(t.gt, .Mode, &mc)
}

// Replies to queries (DA, DSR, kitty keyboard query, ...) go back to the app.
on_write_pty :: proc "c" (gt: gh.Terminal, userdata: rawptr, data: [^]u8, n: c.size_t) {
	context = app_context
	t := (^Term)(userdata)
	if t.mute_replies {
		t.replies_dropped += 1
		return
	}
	pty_write(&t.pty, data[:n])
}

// Bytes the program printed while no Deckhand was reading (the holder's tail, at adopt): into
// the terminal, but every reply to a query in them is dropped, all of them (§7.2 P4). The
// program asked long ago; a stale `^[[?1;2c` must never land in vim. TUIs handle the timeout.
term_feed_replayed :: proc(t: ^Term, bytes: []u8) {
	if len(bytes) == 0 do return
	t.mute_replies = true
	gh.terminal_vt_write(t.gt, raw_data(bytes), len(bytes))
	t.mute_replies = false
	t.cont_fed += len(bytes)
	if t.cont_fed >= CONT_TRIM_EVERY && term_continuation_trim(t.gt) do t.cont_fed = 0
	t.changed = true
}

term_free :: proc(t: ^Term) {
	drag_end(t)
	term_link_clear(t)
	reader_stop_and_close(t)
	delete(t.reader.inbox)
	gh.mouse_event_free(t.mev)
	gh.mouse_encoder_free(t.menc)
	gh.key_event_free(t.kev)
	gh.key_encoder_free(t.kenc)
	gh.render_state_row_cells_free(t.cells)
	gh.render_state_row_iterator_free(t.it)
	gh.render_state_free(t.rs)
	gh.terminal_free(t.gt)
	prog_free(&t.prog)
}

// Starts argv on a fresh terminal (old child hung up, screen reset).
// False if the process could not be started.
term_start :: proc(t: ^Term, argv: []string, cwd: string, extra_env: []string = nil, start: Held_Start = {}) -> bool {
	reader_stop_and_close(t)
	term_cancel_drag(t) // its tracked ends belong to the old terminal
	// a new terminal per process: clean modes, scrollback and kitty flags
	gh.terminal_free(t.gt)
	term_new_gt(t)
	prog_reset(&t.prog) // a new process: the old one's status goes
	t.prog.dirty = true // and the tab re-syncs at the next pump, whatever it showed
	gh.terminal_resize(t.gt, t.cols, t.rows, u32(font.cell_w), u32(font.cell_h))
	t.exit, t.eof_at, t.hung_pid = {}, {}, 0
	t.inexact, t.holder_lost, t.holder_away = false, false, 0
	px_w, px_h := u32(f32(t.cols) * font.cell_w), u32(f32(t.rows) * font.cell_h)
	// keep_sessions: a tab's process lives in the session holder (holder_client.odin)
	tab_id: u64
	for id, x in terms do if x == t do tab_id = id
	p: Pty
	ok: bool
	// a tab's (it may not be in its session yet: a new session's pi tab), not the setup sheet's install run
	if tab_id != 0 && tab_id != harness_run.term_id && holder_wanted() {
		p, ok = holder_spawn(argv, cwd, child_env(extra_env), t.cols, t.rows, px_w, px_h)
		if ok do socket_tokens_bind(tab_id, p.held, start) // its tokens (minted for its env) and what it is are kept with it
		else do fmt.eprintln("Deckhand: session holder: SPAWN failed; this tab runs on its own PTY (it stops at quit)")
	}
	if !ok {
		p, ok = pty_spawn(argv, cwd, child_env(extra_env), t.cols, t.rows)
	}
	if !ok {
		msg := "\x1b[31mfailed to start process\x1b[0m\r\n"
		gh.terminal_vt_write(t.gt, raw_data(msg), len(msg))
		t.running = false
	} else {
		t.pty = p
		t.running = true
		if p.held == 0 {
			reader_start(t)
			pty_resize(&t.pty, t.cols, t.rows, px_w, px_h)
		} else {
			t.reader.eof = false // the holder client feeds the inbox (holder_pull); SPAWN had the size
		}
	}
	t.changed = true
	return ok
}

// Environment for the child: ours, minus the identity of whatever terminal
// launched pi-desk (and any pi-desk token it had), plus our own TERM and
// `extra` (a pi tab's DECKHAND_SOCKET and DECKHAND_TOKEN).
child_env :: proc(extra: []string = nil) -> []string {
	env := child_base_env() // after "Refresh shell environment", the refreshed one (login_env.odin)
	out := make([dynamic]string, context.temp_allocator)
	drop := [?]string{"TERM=", "TERM_PROGRAM", "COLORTERM=", "KITTY_", "GHOSTTY_", "ITERM_", "WEZTERM_", "TMUX", "STY=", "VTE_", "LC_TERMINAL", "PI_DESK_SOCKET=", "PI_DESK_TOKEN=", "PI_DESK_CONTROL_TOKEN=", "DECKHAND_SOCKET=", "DECKHAND_TOKEN=", "DECKHAND_CONTROL_TOKEN=", "DECKHAND_SHOTS_DIR=", "PI_DESK_DATA_DIR=", "PI_DESK_SHOTS_DIR=", "PI_DESK_CLAUDE_TOKEN=", "PI_DESK_CLI=", "PI_DESK_CLAUDE_TAB=", "PI_DESK_GUI_LAUNCH=", "PI_KIT_READONLY=", "PI_DESK_CLAUDE_READONLY=", "PI_DESK_CLAUDE_ACCOUNT="} // a chat sets its own PI_KIT_READONLY, a read-only Claude tab its PI_DESK_CLAUDE_READONLY, a Claude tab its account
	// a Claude tab's account (claude_accounts.odin): its CLAUDE_CONFIG_DIR replaces the inherited
	// one; "!CLAUDE_CONFIG_DIR" drops it
	own_config := false
	for x in extra do if strings.has_prefix(x, "CLAUDE_CONFIG_DIR=") || x == "!CLAUDE_CONFIG_DIR" do own_config = true
	outer: for e in env {
		for d in drop do if strings.has_prefix(e, d) do continue outer
		if own_config && strings.has_prefix(e, "CLAUDE_CONFIG_DIR=") do continue
		append(&out, e)
	}
	append(&out, "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=pi-desk")
	for x in extra do if !strings.has_prefix(x, "!") do append(&out, x)
	return out[:]
}

// Reads what the child wrote and feeds it to the terminal. Call every frame.
// Reader thread: blocks on the PTY and queues output, so the child never
// waits for our frame loop (vsync, or paused while the window is hidden).
Reader :: struct {
	mu:     sync.Mutex,
	inbox:  [dynamic]u8,
	eof:    bool,
	stop:   bool,
	thread: ^thread.Thread,
}

INBOX_CAP :: 16 * 1024 * 1024 // stop reading (child blocks) past this backlog

reader_main :: proc(t: ^Term) {
	r := &t.reader
	buf := make([]u8, 64 * 1024)
	defer delete(buf)
	for !sync.atomic_load(&r.stop) {
		sync.lock(&r.mu)
		backlog := len(r.inbox)
		sync.unlock(&r.mu)
		if backlog > INBOX_CAP {
			time.sleep(time.Millisecond)
			continue
		}
		if !pty_wait_readable(&t.pty, 100) do continue
		n := pty_read(&t.pty, buf)
		if n == 0 do continue
		sync.lock(&r.mu)
		if n < 0 do r.eof = true
		else do append(&r.inbox, ..buf[:n])
		sync.unlock(&r.mu)
		if n < 0 do return
	}
}

reader_start :: proc(t: ^Term) {
	t.reader.stop = false
	t.reader.eof = false
	t.reader.thread = thread.create_and_start_with_poly_data(t, reader_main)
}

// Stops the reader and closes the PTY (hangs up the child).
reader_stop_and_close :: proc(t: ^Term) {
	if t.reader.thread != nil {
		sync.atomic_store(&t.reader.stop, true)
		thread.join(t.reader.thread) // returns within the 100 ms poll timeout
		thread.destroy(t.reader.thread)
		t.reader.thread = nil
	}
	if pty_open(&t.pty) do pty_close(&t.pty)
	clear(&t.reader.inbox)
}

// Feeds queued child output to the terminal. Call every frame.
term_pump :: proc(t: ^Term) {
	if !pty_open(&t.pty) do return
	pty_flush(&t.pty)
	if t.pty.held != 0 do holder_pull(t.pty.held, &t.reader)
	sync.lock(&t.reader.mu)
	n := min(len(t.reader.inbox), READ_BUDGET)
	if n > 0 {
		gh.terminal_vt_write(t.gt, raw_data(t.reader.inbox), uint(n))
		remove_range(&t.reader.inbox, 0, n)
		t.cont_fed += n
		if t.cont_fed >= CONT_TRIM_EVERY && term_continuation_trim(t.gt) do t.cont_fed = 0
	}
	eof := t.reader.eof && len(t.reader.inbox) == 0
	sync.unlock(&t.reader.mu)
	if n > 0 {
		t.changed = true
		t.bytes_in += n
		t.last_output = time.tick_now()
	}
	if eof && t.running {
		// how it ended: its terminal closes a moment before the process is
		// reaped, so it may take a frame or two; one that keeps running
		// without its terminal is hung up on after EXIT_REAP_WAIT (unknown)
		if !t.exit.known {
			if e, reaped := pty_try_reap(&t.pty); reaped do t.exit = e
			else {
				if t.eof_at == {} do t.eof_at = time.tick_now()
				if time.tick_since(t.eof_at) < EXIT_REAP_WAIT do return
			}
		}
		t.running = false
		if !t.exit.known do t.hung_pid = t.pty.pid // reader_stop_and_close hangs up on it
		how := exit_text(t.exit)
		if t.pty.held != 0 && holder_term_lost(t.pty.held) {
			t.holder_lost = true
			if holder_alive() do t.holder_away = t.pty.held // it runs on there: never restarted here (tab_held_away)
		}
		msg := t.holder_away != 0 ? "\r\n\x1b[2m[the session holder isn't answering: this session runs on in it]\x1b[0m" : t.holder_lost ? "\r\n\x1b[2m[the session holder stopped]\x1b[0m" : how != "" ? strings.concatenate({"\r\n\x1b[2m[process exited: ", how, "]\x1b[0m"}, context.temp_allocator) : "\r\n\x1b[2m[process exited]\x1b[0m"
		gh.terminal_vt_write(t.gt, raw_data(msg), len(msg))
		t.changed = true
		reader_stop_and_close(t)
	}
}

// Fits the grid into the pane rect; resizes terminal and PTY on change.
term_set_rect :: proc(t: ^Term, x, y, w, h: f32) {
	t.x, t.y, t.w, t.h = x, y, w, h
	// capped at what a snapshot carries (snapshot.odin), so ours always decode
	cols := u16(clamp(int((w - 2 * term_pad()) / font.cell_w), 2, MAX_TERM_COLS))
	rows := u16(clamp(int((h - 2 * term_pad()) / font.cell_h), 2, MAX_TERM_ROWS))
	if cols == t.cols && rows == t.rows do return
	// a column divider is being dragged: the grid (and the child's PTY)
	// follows at most every RESIZE_THROTTLE; the release resizes it exactly
	if (divider.active || pane_dragging()) && t.cols != 0 && time.tick_since(t.resized) < RESIZE_THROTTLE do return
	t.resized = time.tick_now()
	t.cols, t.rows = cols, rows
	gh.terminal_resize(t.gt, cols, rows, u32(font.cell_w), u32(font.cell_h))
	pty_resize(&t.pty, cols, rows, u32(f32(cols) * font.cell_w), u32(f32(rows) * font.cell_h))
	t.changed = true
}

rgba :: proc(c: gh.Color_Rgb, a: u8 = 255) -> Rgba {return {c.r, c.g, c.b, a}}

Glyph_Draw :: struct {
	x, y:  f32, // cell top-left
	run:   u32, // shaped run (font.odin)
	cells: int,
	col:   Rgba,
}

// Draws the whole grid (inside draw_begin/draw_end).
term_draw :: proc(t: ^Term) {
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
send_key :: proc(t: ^Term, action: gh.Key_Action, key: gh.Key, mods: gh.Mods, unshifted: rune, text: string) {
	if !t.running do return
	gh.key_encoder_setopt_from_terminal(t.kenc, t.gt)
	opt := OPTION_AS_ALT
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
		pty_write(&t.pty, out[:n])
		term_scroll_to_bottom(t)
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

kitty_flags :: proc(t: ^Term) -> u8 {
	f: u8
	gh.terminal_get(t.gt, .Kitty_Keyboard_Flags, &f)
	return f
}

term_key_down :: proc(t: ^Term, e: ^sapp.Event) {
	if s := mac_key_text(e.key_code, e.modifiers, kitty_flags(t) != 0); s != "" {
		t.char_handled = true
		if t.running {
			pty_write(&t.pty, transmute([]u8)s)
			term_scroll_to_bottom(t)
		}
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

term_key_up :: proc(t: ^Term, e: ^sapp.Event) {
	if mac_key_text(e.key_code, e.modifiers, kitty_flags(t) != 0) != "" do return // its press was text, not a key
	key, unshifted := map_key(e.key_code)
	if key == .Unidentified do return
	send_key(t, .Release, key, to_mods(e.modifiers), unshifted, "")
}

term_char :: proc(t: ^Term, e: ^sapp.Event) {
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

// ---- paste, copy, focus ----

mode_on :: proc(t: ^Term, n: u16) -> bool {
	mc := gh.Mode_Config{mode = gh.mode_dec(n)}
	gh.terminal_get(t.gt, .Mode, &mc)
	return mc.value
}

term_paste :: proc(t: ^Term, text: string) {
	if !t.running || len(text) == 0 do return
	data := transmute([]u8)strings.clone(text, context.temp_allocator)
	out := make([]u8, len(data) + 16, context.temp_allocator)
	n: uint
	if gh.paste_encode(raw_data(data), len(data), mode_on(t, 2004), raw_data(out), len(out), &n) == .Success {
		pty_write(&t.pty, out[:n])
		term_scroll_to_bottom(t)
	}
}

// Selected text as a string (temp allocator), "" without a selection.
term_selection_text :: proc(t: ^Term) -> string {
	sel := gh.Selection{size = size_of(gh.Selection)}
	if gh.terminal_get(t.gt, .Selection, &sel) != .Success do return ""
	opts := gh.Selection_Format_Options{size = size_of(gh.Selection_Format_Options), emit = .Plain, unwrap = true, trim = true, selection = &sel}
	p: [^]u8
	n: uint
	if gh.terminal_selection_format_alloc(t.gt, nil, opts, &p, &n) != .Success do return ""
	s := strings.clone(string(p[:n]), context.temp_allocator)
	gh.free(nil, p, n)
	return s
}

term_focus :: proc(t: ^Term, focused: bool) {
	t.focused = focused
	t.changed = true
	if !t.running || !mode_on(t, 1004) do return
	out: [16]u8
	n: uint
	if gh.focus_encode(focused ? .Gained : .Lost, &out[0], len(out), &n) == .Success do pty_write(&t.pty, out[:n])
}

term_scroll_to_bottom :: proc(t: ^Term) {
	sv := gh.Scroll_Viewport{tag = .Bottom}
	gh.terminal_scroll_viewport(t.gt, sv)
	t.changed = true
}

// ---- mouse ----

in_pane :: proc(t: ^Term, mx, my: f32) -> bool {
	return mx >= t.x && mx < t.x + t.w && my >= t.y && my < t.y + t.h
}

cell_at :: proc(t: ^Term, mx, my: f32) -> [2]u16 {
	cx := clamp(int((mx - t.x - term_pad()) / font.cell_w), 0, int(t.cols) - 1)
	cy := clamp(int((my - t.y - term_pad()) / font.cell_h), 0, int(t.rows) - 1)
	return {u16(cx), u16(cy)}
}

app_tracks_mouse :: proc(t: ^Term) -> bool {
	mt: gh.Mouse_Tracking
	gh.terminal_get(t.gt, .Mouse_Tracking, &mt)
	return mt != .None
}

@(private = "file")
send_mouse :: proc(t: ^Term, action: gh.Mouse_Action, button: gh.Mouse_Button, mx, my: f32, mods: gh.Mods) {
	if !t.running do return
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
	if gh.mouse_encoder_encode(t.menc, t.mev, &out[0], len(out), &n) == .Success && n > 0 do pty_write(&t.pty, out[:n])
}

// Screen coordinates (scrollback included) of a viewport cell.
@(private = "file")
to_screen :: proc(t: ^Term, c: [2]u16) -> [2]u32 {
	p := gh.Point{tag = .Viewport}
	p.value.coordinate = {x = c.x, y = u32(c.y)}
	ref := gh.Grid_Ref{size = size_of(gh.Grid_Ref)}
	out: gh.Point_Coordinate
	if gh.terminal_grid_ref(t.gt, p, &ref) != .Success || gh.terminal_point_from_grid_ref(t.gt, &ref, .Screen, &out) != .Success do return {u32(c.x), u32(c.y)}
	return {u32(out.x), out.y}
}

@(private = "file")
set_selection :: proc(t: ^Term, a, b: [2]u32) {
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
selection_start :: proc(t: ^Term) -> ([2]u32, bool) {
	sel := gh.Selection{size = size_of(gh.Selection)}
	if gh.terminal_get(t.gt, .Selection, &sel) != .Success do return {}, false
	out: gh.Point_Coordinate
	if gh.terminal_point_from_grid_ref(t.gt, &sel.start, .Screen, &out) != .Success do return {}, false
	return {u32(out.x), out.y}, true
}

clear_selection :: proc(t: ^Term) {
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
term_mouse_down :: proc(t: ^Term, e: ^sapp.Event, clicks: int) {
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
track :: proc(t: ^Term, i: int, p: [2]u32) {
	gh.tracked_grid_ref_free(t.sel_refs[i])
	t.sel_refs[i] = nil
	pt := gh.Point{tag = .Screen}
	pt.value.coordinate = {x = u16(p.x), y = p.y}
	gh.terminal_grid_ref_track(t.gt, pt, &t.sel_refs[i])
}

// Where the drag's end i is now (screen coordinates); false if its row is gone.
@(private = "file")
tracked :: proc(t: ^Term, i: int) -> ([2]u32, bool) {
	if t.sel_refs[i] == nil do return {}, false
	out: gh.Point_Coordinate
	if gh.tracked_grid_ref_point(t.sel_refs[i], .Screen, &out) != .Success do return {}, false
	return {u32(out.x), out.y}, true
}

// The drag is over (the selection stays): its tracked ends are freed.
@(private = "file")
drag_end :: proc(t: ^Term) {
	t.selecting = false
	for &r in t.sel_refs {
		gh.tracked_grid_ref_free(r)
		r = nil
	}
}

// A drag cut short (tab or session change, the window lost focus): no more
// selecting or auto-scroll, and no release for the app either.
term_cancel_drag :: proc(t: ^Term) {
	drag_end(t)
	t.mouse_down = false
	t.mouse_button = .Unknown
}

term_mouse_up :: proc(t: ^Term, e: ^sapp.Event) {
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

term_mouse_move :: proc(t: ^Term, e: ^sapp.Event) {
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
select_to :: proc(t: ^Term, vc: [2]u16) {
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
term_drag_tick :: proc(t: ^Term, left_down: bool) {
	if !t.selecting || t.rows == 0 do return
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
word_cells :: proc(t: ^Term, c: [2]u16) -> (lo, hi: [2]u16) {
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
row_runes :: proc(t: ^Term, y: int) -> []rune {
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
term_text_input :: proc(t: ^Term, text: string) {
	if !t.running || text == "" do return
	pty_write(&t.pty, transmute([]u8)text)
	term_scroll_to_bottom(t)
}

// An input method's composition at the cursor: drawn over the cells,
// underlined, with a caret.
term_draw_marked :: proc(t: ^Term, marked: string, caret: int) {
	if marked == "" do return
	th := theme()
	x, y := t.cursor_px.x, t.cursor_px.y
	w := text_width(marked, .Mono)
	draw_rect(x, y, w, font.cell_h, th.term_bg)
	draw_text(x, y, marked, th.term_fg, .Mono)
	draw_rect(x, y + font.cell_h - font.line_thick, w, font.line_thick, th.term_fg)
	draw_rect(x + text_width(marked[:clamp(caret, 0, len(marked))], .Mono), y, max(1, font.line_thick), font.cell_h, th.term_cursor)
}

// Wheel: to the app as button 4/5 when it tracks the mouse, as arrow keys on
// the alternate screen, else scrolls our scrollback. Trackpads deliver
// fractional deltas, so whole steps are accumulated.
term_scroll :: proc(t: ^Term, e: ^sapp.Event) {
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
