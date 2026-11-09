package core

// Terminal pane, the core's side: a child process on our own PTY, its output parsed by
// libghostty-vt, which answers the program's queries. The window keeps its own copy of each
// terminal it shows (term_view.odin, design §5.5): the core streams it the same bytes
// (term_stream.odin), and the window draws it cell by cell and encodes keyboard, mouse and paste
// input with libghostty-vt's encoders from its copy's modes (legacy, kitty keyboard, SGR mouse,
// bracketed paste). Every byte this terminal parses goes through term_vt_write, so the stream's
// offsets count exactly what both copies parse.

import "core:c"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import gh "../ghostty"

OPTION_AS_ALT :: gh.Option_As_Alt.True // macOS: Option+key sends Alt (pi's Alt+Enter)
READ_BUDGET :: 4 * 1024 * 1024 // max PTY bytes parsed per frame
EXIT_REAP_WAIT :: time.Second // after a child's output ended, how long it may take to exit

Term :: struct {
	gt:           gh.Terminal,
	pty:          Pty,
	reader:       Reader,
	running:      bool,
	exit:         Exit_Info, // once it exited: how (waitpid)
	eof_at:       time.Tick, // its output ended; waiting to reap it (EXIT_REAP_WAIT)
	hung_pid:     i32, // not reaped by then: hung up on, maybe still dying (a restart waits for it)
	cols, rows:   u16,
	cell:         [2]f32, // one cell in pixels, as the window measured it (term_resize): the pixel sizes reported to the program
	// set when something visible changed; the frame loop redraws then
	changed:      bool,
	bytes_in:     int, // stats
	last_output:  time.Tick, // last PTY output (the "running" placeholder, ui.odin)
	// what the program reports over OSC 7501 (agent_status.odin); its summary goes to the tab
	prog:         Prog_Records,
	cont_fed:     int, // bytes fed since the continuation buffer was last trimmed
	// a terminal adopted from the session holder (holder_adopt.odin)
	inexact:      bool, // not rebuilt byte-exactly (no snapshot, or the holder's tail had a gap)
	holder_lost:  bool, // its process ran in a holder that went away
	holder_away:  u32, // that holder still runs (lost, not gone): its terminal id, the process runs on there
	mute_replies: bool, // feeding replayed bytes: query replies are dropped (§7.2 P4)
	replies_dropped: int, // how many (tests)
	// the stream offset: every byte gt parsed (term_vt_write), the program's and Deckhand's own
	// notes alike; never reset (a new gt is sent as a snapshot at the offset reached)
	offset:       u64,
}

// The cell size (framebuffer px) the window measured last (fonts_apply, font.odin): a new
// terminal starts with it, until the window sizes it to its pane (term_resize).
term_cell: [2]f32

// Default fg/bg/cursor/palette from the active look (term_palette.odin). Programs
// that set their own colours (OSC 4/10/11) keep them.
term_apply_theme :: proc(t: ^Term) {
	gt_apply_theme(t.gt, term_colors())
	t.changed = true
	term_report_color_scheme(t)
}

// The look's default colours on any terminal: the core's, and the window's copy (term_view.odin),
// which sets them itself (they are not in the byte stream).
gt_apply_theme :: proc(gt: gh.Terminal, tc: ^Term_Colors) {
	fg := gh.Color_Rgb{tc.fg.r, tc.fg.g, tc.fg.b}
	bg := gh.Color_Rgb{tc.bg.r, tc.bg.g, tc.bg.b}
	cc := gh.Color_Rgb{tc.cursor.r, tc.cursor.g, tc.cursor.b}
	pal := term_palette(tc)
	gh.terminal_set(gt, .Color_Foreground, &fg)
	gh.terminal_set(gt, .Color_Background, &bg)
	gh.terminal_set(gt, .Color_Cursor, &cc)
	gh.terminal_set(gt, .Color_Palette, &pal)
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
// 2027), then term_attach_gt. A window streaming t gets it as a snapshot.
term_new_gt :: proc(t: ^Term) -> bool {
	if gh.terminal_new(nil, &t.gt, t.cols, t.rows) != .Success do return false
	grapheme_clusters(t)
	term_attach_gt(t)
	term_stream_reset(t) // term_stream.odin
	return true
}

// What Deckhand sets on every terminal that a snapshot does not carry, the
// core's and the window's copies alike (the one helper for both, design §5.5):
// the scrollback limit, continuation tracking (so it can be snapshotted at any
// byte offset) and the look's default colours (programs' own colours stay).
// The core's also gets its callbacks (term_attach_gt); a window's copy gets
// none: it never answers queries (write_pty is dropped) or reads OSC 7501/133.
gt_setup :: proc(gt: gh.Terminal, tc: ^Term_Colors) {
	max_bytes := uint(TERM_SCROLLBACK_MAX)
	gh.terminal_set(gt, .Scrollback_Max_Bytes, &max_bytes)
	// a decoded terminal that kept its continuation (DECODER_OPT_RETAIN_CONTINUATION) has the limit
	// already: set again, the unfinished sequence it holds would be dropped
	cont, have: c.size_t
	gh.terminal_get(gt, .Continuation_Max_Bytes, &have)
	cont = TERM_CONTINUATION_MAX
	if have != cont do gh.terminal_set(gt, .Continuation_Max_Bytes, &cont)
	gt_apply_theme(gt, tc)
}

// What Deckhand hangs on the core's terminal: gt_setup, then the callbacks
// (query replies, colour scheme, OSC 7501/133). Run on every new terminal and
// on one decoded from a snapshot (term_adopt_gt).
term_attach_gt :: proc(t: ^Term) {
	gt_setup(t.gt, term_colors())
	gh.terminal_set(t.gt, .Userdata, t)
	gh.terminal_set(t.gt, .Write_Pty, rawptr(on_write_pty))
	gh.terminal_set(t.gt, .Color_Scheme, rawptr(on_color_scheme))
	term_status_register(t) // OSC 7501 and OSC 133 (agent_status.odin)
	t.cont_fed = 0
	t.changed = true
	term_report_color_scheme(t)
}

// Replaces t's terminal with gt (decoded from a snapshot; t takes ownership)
// and re-attaches Deckhand's callbacks, scrollback limit, cell pixel size and
// theme, as term_start sets them. Modes and grapheme clustering come from the
// snapshot.
term_adopt_gt :: proc(t: ^Term, gt: gh.Terminal) {
	if t.gt != nil do gh.terminal_free(t.gt)
	t.gt = gt
	gh.terminal_get(gt, .Cols, &t.cols)
	gh.terminal_get(gt, .Rows, &t.rows)
	gh.terminal_resize(t.gt, t.cols, t.rows, u32(t.cell.x), u32(t.cell.y))
	term_attach_gt(t)
	term_stream_reset(t) // a window streaming t gets the new terminal as a snapshot (term_stream.odin)
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
	t.cell = term_cell
	if !term_new_gt(t) do return false
	t.pty.fd = -1
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
	term_vt_write(t, bytes)
	t.mute_replies = false
	t.changed = true
}

// Bytes into the core's terminal: parsed, counted at the stream offset, and queued for every
// window that streams it (term_stream.odin), so its copy parses exactly the same bytes. Every
// write into a Term's gt goes through here (the program's output and Deckhand's own notes).
term_vt_write :: proc(t: ^Term, bytes: []u8) {
	if len(bytes) == 0 do return
	gh.terminal_vt_write(t.gt, raw_data(bytes), len(bytes))
	t.offset += u64(len(bytes))
	t.cont_fed += len(bytes)
	if t.cont_fed >= CONT_TRIM_EVERY && term_continuation_trim(t.gt) do t.cont_fed = 0
	term_stream_bytes(t, bytes)
}

term_free :: proc(t: ^Term) {
	term_stream_term_gone(t) // its windows' channels close (term_stream.odin)
	reader_stop_and_close(t)
	delete(t.reader.inbox)
	gh.terminal_free(t.gt)
	prog_free(&t.prog)
}

// Starts argv on a fresh terminal (old child hung up, screen reset).
// False if the process could not be started.
term_start :: proc(t: ^Term, argv: []string, cwd: string, extra_env: []string = nil, start: Held_Start = {}) -> bool {
	reader_stop_and_close(t)
	// a new terminal per process: clean modes, scrollback and kitty flags
	gh.terminal_free(t.gt)
	term_new_gt(t)
	prog_reset(&t.prog) // a new process: the old one's status goes
	t.prog.dirty = true // and the tab re-syncs at the next pump, whatever it showed
	gh.terminal_resize(t.gt, t.cols, t.rows, u32(t.cell.x), u32(t.cell.y))
	t.exit, t.eof_at, t.hung_pid = {}, {}, 0
	t.inexact, t.holder_lost, t.holder_away = false, false, 0
	px_w, px_h := u32(f32(t.cols) * t.cell.x), u32(f32(t.rows) * t.cell.y)
	// keep_sessions: a tab's process lives in the session holder (holder_client.odin)
	tab_id: u64
	for id, x in terms do if x == t do tab_id = id
	if id_machine(tab_id) != 0 do return false // another machine's tab (machine_mirror.odin): it runs there, never here
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
		term_vt_write(t, transmute([]u8)msg)
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
// launched Deckhand (and any Deckhand token it had, under either name), plus our own TERM and
// `extra` (a pi tab's DECKHAND_SOCKET and DECKHAND_TOKEN).
child_env :: proc(extra: []string = nil) -> []string {
	env := child_base_env() // after "Refresh shell environment", the refreshed one (login_env.odin)
	out := make([dynamic]string, context.temp_allocator)
	drop := [?]string{"TERM=", "TERM_PROGRAM", "COLORTERM=", "KITTY_", "GHOSTTY_", "ITERM_", "WEZTERM_", "TMUX", "STY=", "VTE_", "LC_TERMINAL", "PI_KIT_READONLY="} // a chat sets its own PI_KIT_READONLY; what Deckhand sets its tabs (env_desk_set, both names) goes below
	// a Claude tab's account (claude_accounts.odin): its CLAUDE_CONFIG_DIR replaces the inherited
	// one; "!CLAUDE_CONFIG_DIR" drops it
	own_config := false
	for x in extra do if strings.has_prefix(x, "CLAUDE_CONFIG_DIR=") || x == "!CLAUDE_CONFIG_DIR" do own_config = true
	outer: for e in env {
		for d in drop do if strings.has_prefix(e, d) do continue outer
		// Deckhand's own names (tokens, the CLI, a read-only Claude tab's DECKHAND_CLAUDE_READONLY, a
		// Claude tab's account), new and old: an explicit list, so the user's DECKHAND_SIGN_IDENTITY
		// and the like pass (env_names.odin)
		if env_tab_dropped(env_key(e)) do continue outer
		// a data dir of test mode's never reaches a tab (release builds have no such variable)
		when TEST_HOOKS do if strings.has_prefix(e, HOOK_ENV[.Data_Dir]) && strings.has_prefix(e[len(HOOK_ENV[.Data_Dir]):], "=") do continue outer
		when TEST_HOOKS do if strings.has_prefix(e, "PI_DESK_DATA_DIR=") do continue outer // its old name (test_hooks.odin hook_lookup)
		if own_config && strings.has_prefix(e, "CLAUDE_CONFIG_DIR=") do continue
		append(&out, e)
	}
	append(&out, "TERM=xterm-256color", "COLORTERM=truecolor", "TERM_PROGRAM=Deckhand")
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
		first := len(r.inbox) == 0 // the main thread took everything: it may be asleep (output_wake)
		if n < 0 do r.eof = true
		else do append(&r.inbox, ..buf[:n])
		sync.unlock(&r.mu)
		if first do output_wake()
		if n < 0 do return
	}
}

reader_start :: proc(t: ^Term) {
	t.reader.stop = false
	t.reader.eof = false
	t.reader.thread = thread.create_and_start_with_poly_data(t, reader_main)
}

// A separate core (deckhand-core serve) has no frames: its loop sleeps until woken or its timer
// fires, and its timer slows to CORE_TIMER_SLOW when idle (and App Nap stretches it). So a
// reader's first bytes after the main thread took them all wake the loop at once (§10.3 M4-C),
// and the loop runs again at once while any terminal has more than a tick parsed (output_backlog).
// Off in process: the window's frames run the core. Any thread.
output_wake_on: bool

output_wake :: proc() {
	if sync.atomic_load(&output_wake_on) && platform.wake != nil do platform.wake()
}

// Some terminal has output waiting past what this tick parsed (READ_BUDGET): the loop goes again
// without sleeping. Main thread.
output_backlog :: proc() -> bool {
	for _, t in terms {
		sync.lock(&t.reader.mu)
		n := len(t.reader.inbox)
		sync.unlock(&t.reader.mu)
		if n > 0 do return true
	}
	return holder_output_waiting()
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
		term_vt_write(t, t.reader.inbox[:n])
		remove_range(&t.reader.inbox, 0, n)
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
		term_vt_write(t, transmute([]u8)msg)
		t.changed = true
		reader_stop_and_close(t)
	}
}

// The grid is cols x rows of cells cell_w x cell_h framebuffer px (the window works them out
// from its pane and font: term_set_rect, term_view.odin): the terminal and the program's PTY
// follow. Nothing happens when nothing changed.
term_resize :: proc(t: ^Term, cols, rows: u16, cell_w, cell_h: f32) {
	if cols == t.cols && rows == t.rows && cell_w == t.cell.x && cell_h == t.cell.y do return
	t.cols, t.rows, t.cell = cols, rows, {cell_w, cell_h}
	gh.terminal_resize(t.gt, cols, rows, u32(cell_w), u32(cell_h))
	pty_resize(&t.pty, cols, rows, u32(f32(cols) * cell_w), u32(f32(rows) * cell_h))
	term_stream_resized(t) // its windows' copies resize at this byte offset (term_stream.odin)
	t.changed = true
}

// ---- paste, copy ----

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
term_selection_text :: proc(t: ^Term) -> string {return gt_selection_text(t.gt)}

// The same for any terminal (the window's copy holds the user's selection: term_view.odin).
gt_selection_text :: proc(gt: gh.Terminal) -> string {
	sel := gh.Selection{size = size_of(gh.Selection)}
	if gh.terminal_get(gt, .Selection, &sel) != .Success do return ""
	opts := gh.Selection_Format_Options{size = size_of(gh.Selection_Format_Options), emit = .Plain, unwrap = true, trim = true, selection = &sel}
	p: [^]u8
	n: uint
	if gh.terminal_selection_format_alloc(gt, nil, opts, &p, &n) != .Success do return ""
	s := strings.clone(string(p[:n]), context.temp_allocator)
	gh.free(nil, p, n)
	return s
}

// The core typed or pasted into t (a command): the window's copy scrolls back down too, as it
// does when the user types (term_stream.odin's term.scroll).
term_scroll_to_bottom :: proc(t: ^Term) {
	sv := gh.Scroll_Viewport{tag = .Bottom}
	gh.terminal_scroll_viewport(t.gt, sv)
	term_stream_scroll_bottom(t)
	t.changed = true
}

