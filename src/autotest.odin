package main

// Scripted input for testing without touching other apps: when
// DECKHAND_SCRIPT=<file> is set, each line is played in order from the frame
// loop, and synthetic sokol events go through the normal event() handler.
// OS-level input (Cocoa -> sokol) is therefore NOT covered by these runs.
//
//   wait MS                    sleep (frames keep running); for checks that something stays as it
//                              was, timing and idle measurements. A check that waits for something
//                              to happen uses `eventually` (docs/TESTING.md, "Waits")
//   eventually [MS]            the checks (assert_*) right after this line are tried again every
//                              frame until each passes, for up to MS (default 10 s); then they fail
//                              as before. The first line that is not a check ends it
//   waitfor TEXT [MS]          until TEXT is on screen (default 30 s)
//   waitresult MS PATH VALUE   the `command` line before it (a read-only one: changes_list,
//                              editor_state...) is run again until its result has VALUE at PATH
//   (clickid, rclickid, hover, sweep, dragid, clickmenu, clickmd, clicktext, divider and drop read
//   the last layout: they wait for a frame drawn after the last input, and for up to 5 s for an
//   element that is not laid out yet, before failing as before)
//   type TEXT                  KEY_DOWN/CHAR/KEY_UP per character
//   key NAME [shift|ctrl|alt|cmd ...]   enter tab backspace escape up down left right
//                              pageup pagedown home end space comma slash lcmd (⌘ alone), or a letter/digit
//   paste TEXT                 Cmd+V of TEXT ("\n" -> newline; the script's own pasteboard, not the system's)
//   scroll DY X Y              wheel at logical X,Y
//   click X Y                  left click at logical X,Y
//   drag X1 Y1 X2 Y2 [shift] [held]   left drag (held: the moves say the button is down, as macOS's do)
//   clicks N X Y               N quick left clicks at logical X,Y (2 = double-click)
//   clickcell N COL ROW [COL2 ROW2]  N quick clicks on a terminal cell (then drag to COL2,ROW2)
//   mousecell down|move|up COL ROW [shift|cmd|ctrl ...]   one step of a press held across frames
//                              (a drag the frame loop draws in between); COL/ROW may be off the grid;
//                              hover (a move, no button), click, rclick (right button) too;
//                              pane=SLOT: in that pane's terminal (else the focused tab's)
//   assert_link URL|-          the terminal link underlined under the pointer (⌘ held), or none
//   assert_drawn_selection N   the last drawn frame showed selected terminal cells (N > 0) or none (0)
//   clicktext N NAME OFFSET    N quick clicks in a text element at byte OFFSET of its text
//   beeps [WANT]               AppKit beeps for unhandled keys so far (counted, not sounded;
//                              the first use starts counting); with WANT, assert the count
//   panels [WANT]              AppKit's Emoji & Symbols panel and dictation opened so far
//                              (counted, not opened; the first use starts counting)
//   assert_screen TEXT         TEXT is on the active terminal's screen now
//   assert_not_screen TEXT     TEXT is not on the active terminal's screen now
//   assert_palette INDEX KEY   the palette's result INDEX has KEY (action:new_chat, tab:3, ...)
//   assert_selection TEXT      the focused field's selection, else the terminal's, equals TEXT
//                              (read directly: the system clipboard is not touched)
//   assert_pane_selection SLOT TEXT  the terminal selection of the tab pane SLOT shows ("" = none)
//   assert_pane_cols SLOT      the terminal pane SLOT shows has the columns of its pane's width now
//   ime_mark TEXT              an input method's composition (setMarkedText), as macOS sends it
//   ime_commit TEXT            committed text outside a key press (emoji picker), insertText
//   ime_key CODE TEXT [alt|cmd|ctrl|shift|repeat ...]   a key press and release through
//                              keyDown:/keyUp: (NSEvents built in-process); TEXT: the
//                              characters, or enter backspace tab escape space left right up down delete
//   ime_press CODE CHARS [alt] [repeat] -- OP...   a key press through keyDown: whose input
//                              method calls are OPs (mark=T insert=T cmd=SELECTOR unmark)
//                              instead of the system's; CHARS: enter, - (none), or text
//   hittest X Y WANT           what a real click at logical X,Y reaches: view | titlebar
//   lights                     log the traffic lights' centre (logical px) vs the top bar
//   system_appearance light|dark   as if the OS switched appearance (the KVO callback's path)
//   assert_window light|dark   the window's effective appearance (title bar, traffic lights)
//   clickid NAME [INDEX]       left click the centre of a Clay element (proj/sess/new)
//   rclickid NAME [INDEX]      right click there (context menus); for the Files and Settings
//                              rows (frow, fcreate...) INDEX may be @PATH: the drawn row whose
//                              path ends with PATH (e.g. @.pi/settings.json; a setting row's
//                              path is its id, e.g. @deckhand:claude-default-flags), so a row
//                              added above it does not move the click
//   assert_files TEXT          the Files tree's rows (indented names, "/" after open folders)
//                              contain TEXT ("\n" = a line break); assert_not_files: do not
//   dragid FROM INDEX TO       left drag from element FROM INDEX to element TO (centres)
//   dragtab TAB WHERE [SLOT] [GAP] [esc|hold]   left drag of tab TAB (its index in the open
//                              session's tabs) to WHERE: `strip SLOT GAP` (pane SLOT's strip, or
//                              the title bar's with one pane, before its GAP-th tab), `centre SLOT`,
//                              `left|right|up|down SLOT` (that edge's drop zone of pane SLOT's
//                              body), `by DX DY` (logical px from the tab's centre: under the
//                              threshold it is a click), `outside` (released past the window's
//                              right edge, as AppKit still reports it); `esc` presses Escape
//                              before the release; `hold` never releases
//                              (for a shot; `key escape` cancels it) (panes_drag.odin)
//   files_time N DY            lay out N frames, scrolling the Files tree by DY each: time per frame
//   assert_rows SECTION LIST   the left column's rows (open|projects|sessions|chats) as
//                              sidebar.odin lists them, comma-separated names/titles ("-" =
//                              none); tree: the project tree as last drawn, the expanded
//                              project's sessions as ">title"
//   drop WHERE PATH...         files dropped on the window (FILES_DROPPED) at the centre of
//                              WHERE: sidebar | terminal | right
//   pick_folder PATH           what the next folder picker returns (test mode never opens it)
//   divider N DX [clicks]      drag column divider N (0 left, 1 right, 2 the agent drawer's
//                              left edge) by DX logical px;
//                              `clicks 2` double-clicks it instead;
//                              `divider pane SLOT D [clicks N]`: the divider right of (or below)
//                              pane SLOT, by D logical px across it
//   hover NAME [INDEX]         move the pointer to the centre of a Clay element (INDEX: as clickid)
//   sweep NAME INDEX STEPS     move the pointer across a Clay element (left to right, mid
//                              height) in STEPS moves, laying out between them as frames do;
//                              at each point a second move (the jitter of a still hand) must
//                              keep the hover: fails where it flips (hover drawn from a layout
//                              that the hover itself changes)
//   assert_tip [TEXT]          the tooltip showing now is TEXT ("label keys"); none without TEXT
//   waitexit [MS]              until the child process has exited
//   assert_not_drawn TEXT      no text drawn in the window (a fresh layout) contains TEXT
//   assert_notice TEXT         the active editor's status-line notice contains TEXT
//   clickmenu LABEL            left click the open context menu's row LABEL
//   assert_menurows A|-|B      the open context menu's rows ("-" = a divider; notes left out)
//   assert_revealed TEXT|-     the last path shown in Finder contains TEXT; - = none
//   revealed_clear             forget it
//   assert_toast TEXT|-        the toast showing now (toast.odin) contains TEXT; - = none
//   toast_clear                the toast goes away now
//   assert_clipboard TEXT|-    what Deckhand last put on the clipboard contains TEXT; - = nothing
//   clipboard_clear            forget it (the system clipboard is left as it is)
//   assert_md TEXT             the shown Markdown preview's text (labels and markers too)
//                              contains TEXT; assert_not_md: does not
//   clickmd TEXT               left click the middle of the preview's first text piece
//                              containing TEXT (scrolled into view first)
//   assert_opened URL          the last link opened in the default browser or mail app (test
//                              mode only logs it; Markdown and terminal links)
//   state                      log modes the app enabled (mouse, paste, kitty keys)
//   resize W H                 window content size (logical px)
//   shot NAME                  screenshot of this window to build/shots/NAME.png (raised without focus;
//                              taken once 3 frames are drawn after the raise, at least 150 ms)
//   dump NAME                  visible terminal text to build/NAME.txt
//   cpu_begin / cpu_end LABEL  own process CPU% (getrusage) + frames drawn
//   atlas                      glyph atlas size, cached glyphs, rasterised, evictions
//   window back|front          the window goes to the background / comes to the front
//                              (UNFOCUSED/FOCUSED through event(); the app's own idea only)
//   deactivate                 hand focus back to the previously active app
//   minimize / restore         miniaturize / deminiaturize the window
//   hide / unhide              hide the app (⌘H) / show it again (a quit shows it again first:
//                              app_request_quit, main.odin)
//   frames off|on              frame() returns at once, as if macOS stopped calling it (hidden,
//                              App Nap; quiet test mode's hidden window still gets 60 a second):
//                              the core loop's timer ticks the core and this script (core_loop.odin)
//   core_loop                  log the core loop's timer ticks, skips and frames so far
//   menu ID                    pick a menu bar item as a click does (menubar.odin; ID = its action,
//                              or undo, copy, paste...); fails if it is disabled. AppKit's own
//                              items (hide, minimize...) are refused
//   assert_menu ID enabled|disabled|checked|unchecked   the item as AppKit would show it now
//   menu_key CODE CHARS [cmd|shift|alt|ctrl ...] [notkey] [menu|view]   a key press as AppKit
//                              handles it: the menu bar's key equivalents first, else the view
//                              (NSEvents built in-process); with menu|view, assert which took it;
//                              notkey: as if another window (the About panel) had the keyboard
//   menubar_dump NAME          the native menu bar as text (validated now) to build/NAME.txt
//   command JSON               submit a command through the inbox as the script
//                              caller and log its result, e.g.
//                              command {"type":"close_tab","tab_id":$tab}
//                              (waits for "finished" if the result is pending, at most
//                              120 s or the command's timeout_ms + 10 s if longer, then
//                              TIMEOUT (a later result is dropped); a finished event that
//                              comes while the command runs is kept, never missed)
//   ui_command JSON            the same as the user (caller ui), e.g. to change
//                              confirmation settings, which scripts may not
//   thread_command JSON        submit from a worker thread, as a socket would
//                              (no reply; check with assert_state; logs wakes)
//   assert_state PATH VALUE    state JSON at PATH (a.b.0.c; "#" = length) equals VALUE
//   waitstate MS PATH VALUE    until the state JSON has VALUE at PATH (fails after MS)
//   jobs_clock SECONDS         the jobs' scheduler clock moves on (jobs.odin), then a due check
//   window_active on|off       as if Deckhand were in front (no OS notifications) or behind
//   jobs_ui ID|- [limits]      open a Jobs row (and the limits) on the Jobs tab
//   replace_in_file PATH OLD|NEW   edit a file as another program would
//   assert_file PATH TEXT      the file contains TEXT; assert_not_file: does not
//   result_file NAME           the last command's result JSON to build/NAME.json
//   assert_result PATH VALUE   same, on the last command's result JSON
//   assert_finished PATH VALUE same, on the last long-running command's finished result
//   state_json NAME            app state as JSON to build/NAME.json
//   screen_hashes              log every terminal's screen_hash (tab id, holder terminal, hash)
//   quit                       quit without confirmation; exit status 1 if an assert failed. A
//                              separate core quits too (Quit, as in process: keep_sessions holds),
//                              so the next run on the data dir starts a fresh one
//   quit_window                the same, but a separate core runs on (as ⌘Q: two-process, handover)
//
// DECKHAND_SCRIPT_FAIL_FAST=1 (the scenes' default: tests/scripts/fresh-build.sh, tests/scenes.py):
// the first failed check, wait (waitfor, waitstate, waitresult, a command's TIMEOUT...) or missing
// element ends the script there: it logs "ASSERT FAILED (stopped at line N ...)" (no "done:") and
// quits (exit status 1), so a scene
// fails in seconds instead of running every later wait to its timeout. DECKHAND_SCRIPT_STEP=FILE:
// each line's number and text are written to FILE as it starts, so a run that hangs or is killed
// says where it was (tests/scenes.py prints it).
//
// Variables in command/assert lines: $last (last created_id), $token (last
// confirmation token), $project (selected project), $session (current open
// session), $tab (its active tab), $pitab (its pi tab), $pisession (its pi
// session id), $hometab (Home's pi tab), $chats (the Chats entry's project
// id), $homedir ($HOME), $notesdir (the main folder, home_dir), $datadir (the data dir), $cwd (Deckhand's working directory), $pane0…$pane7 (the
// current session's panes by slot), $ptab0…$ptab7 (the tab each shows). assert_screen, waitfor and dump read
// the terminal with the keyboard (Home's while its pane shows).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import "core"
import gh "ghostty"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

Autotest :: struct {
	cpu_core_start: f64, // a separate core: its process's CPU seconds at cpu_begin
	frames_off:   bool, // `frames off`: frame() returns at once, as if the OS stopped calling it
	frames_back:  time.Tick, // ...until then at most (script_frames_off)
	lines:        []string,
	next:         int,
	wait_until:   time.Tick,
	waiting_for:  string,
	wait_state:   [2]string, // waitstate: path, value (owned; "" = none)
	wait_state_at: u64, // a separate core: app.frames_drawn when it was first reached (0: not yet)
	wait_exit:    bool,
	pending_shot: string,
	deadline:     time.Tick,
	cpu_wall:     time.Tick,
	cpu_start:    f64,
	cpu_frames:   u64,
	cpu_bytes:    int,
	cpu_calls:    u64,
	cpu_checks:   f64, // terms_check_cpu at cpu_begin
	wait_request: u64, // pending command: wait for its finished event
	input_synced: bool, // a separate core: the last input's commands ran there before an element line read the layout
	early_request: u64, // a separate core: a finished that came before its command's result was read (script_command)
	early_finished: string, // ...its result's JSON (heap)
	early_created: u64, // ...and the id it made
	wait_request_deadline: time.Tick, // then TIMEOUT (script_finish_timeout)
	replica_checked: time.Tick, // the last divergence check (autotest_check_replica)
	terms_checked:   int, // terminal copies compared with the core's (autotest_check_terms)
	terms_check_cpu: f64, // the CPU seconds those checks took (cpu_end leaves them out: a test-mode cost)
	submitted:    u64, // the command script_command is running: its finished event may come in the same drain
	submitted_done: bool, // it came (last_finished holds it)
	last_result:  string, // JSON of the last command result
	last_finished: string, // JSON of the last long-running command's finished result
	last_created: u64,
	prev_created: u64, // $prev: the one before $last
	last_token:   string,
	asserts:      int,
	failures:     int,
	started:      bool,
	left_down:    bool, // the scripted left button (real input is dropped)
	injecting:    bool, // a script line drives native input: let it through
	fake_folder:  string, // the folder picker's next answer
	opened_url:   string, // the last link a Markdown tab opened (never opened in test mode)
	bg_request:   u64, // pi_command_bg: a long command left running (await_bg waits for it)
	bg_done:      bool,
	bg_deadline:  time.Tick,
	clipboard:    string, // what Deckhand last put on the clipboard (platform.set_clipboard)
	pasteboard:   string, // what a paste inserts: the script's own, never the system's (autotest_platform)
	revealed:     string, // the last path platform.reveal was asked to show
	eventually_on:    bool, // `eventually`: a failing check right after it is tried again next frame
	eventually_until: time.Tick, // until then (then it fails as before)
	retry_line:   int, // the line being tried again (logged once), -1 = none
	elem_until:   time.Tick, // an element-addressed line whose element is missing: tried until then
	input_drawn:  u64, // app.frames_drawn when the last input went in: element lookups wait for a later frame
	input_line:   string, // that input's line (owned)
	shot_drawn:   u64, // app.frames_drawn when a shot raised the window
	shot_at:      time.Tick,
	audit:        bool, // DECKHAND_WAIT_AUDIT=1: log which checks after a `wait` already held before it
	audit_wait:   int, // the `wait` line whose checks are running (C), -1 = none
	audit_k:      int,
	command_idx:  int, // the last `command` line (waitresult runs it again)
	wr_idx:       int, // the waitresult line being waited on, -1 = none
	wr_until:     time.Tick,
	fail_fast:    bool, // DECKHAND_SCRIPT_FAIL_FAST=1: the first failure ends the script
	step_file:    string, // DECKHAND_SCRIPT_STEP: the line running now goes there
	path:         string,
}

// Real keyboard/mouse input is dropped in test mode; script-driven native
// input (ime_*) is let through.
autotest_allows_input :: proc() -> bool {return !core.autotest_active || autotest.injecting}

autotest: Autotest

autotest_init :: proc() {
	path := core.hook_env(.Script)
	if path == "" do return
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("autotest: cannot read", path)
		return
	}
	autotest.lines = strings.split_lines(string(data))
	core.autotest_active = true
	autotest.retry_line, autotest.audit_wait, autotest.wr_idx, autotest.command_idx = -1, -1, -1, -1
	autotest.audit = core.hook_env(.Wait_Audit) == "1"
	autotest.fail_fast = core.hook_env(.Script_Fail_Fast) == "1"
	autotest.step_file = core.hook_env(.Script_Step, context.allocator)
	autotest.path = strings.clone(path)
	if autotest.audit do log("AUDIT script", path)
	autotest_platform()
}

// A script's platform layer: never a modal panel, a Finder window, a browser or the system
// pasteboard. Copies and pastes stay in the app (autotest.pasteboard): scenes run side by side,
// beside other runs, and the pasteboard is shared, so one scene's copy could replace what another
// scene's page just put there, bump the change count browser scenes watch, or replace the user's
// own clipboard. A page (Chromium) still uses the system pasteboard (browser-act).
autotest_platform :: proc() {
	// never a modal panel or a Finder window from a script
	win_os.pick_folder = proc() -> string {
		p := autotest.fake_folder
		autotest.fake_folder = ""
		log("folder picker ->", p)
		return p
	}
	win_os.reveal = proc(path: string) {
		log("reveal", path)
		delete(autotest.revealed)
		autotest.revealed = strings.clone(path)
	}
	// kept for assert_clipboard, and what the next paste inserts
	win_os.set_clipboard = proc(text: string) {
		delete(autotest.clipboard)
		autotest.clipboard = strings.clone(text)
		autotest_paste_set(text)
	}
	win_os.get_clipboard = proc() -> string {return autotest.pasteboard}
	win_os.set_clipboard_secret, win_os.clear_clipboard_if = nil, nil // the script's own pasteboard (set_clipboard)
	win_os.open_url = proc(url: string) -> bool {
		log("open url", url)
		delete(autotest.opened_url)
		autotest.opened_url = strings.clone(url)
		return true
	}
	win_os.left_button = proc() -> bool {return autotest.left_down}
}

autotest_paste_set :: proc(text: string) {
	delete(autotest.pasteboard)
	autotest.pasteboard = strings.clone(text)
}

@(private = "file")
log :: proc(args: ..any) {
	fmt.print("[autotest ", time.now(), "] ", sep = "")
	fmt.println(..args)
}

// The terminal with the keyboard: Home's while its pane shows.
screen_text :: proc() -> string {
	return term_screen_text(key_view())
}

// A terminal's visible text, as the window's copy shows it (temp-allocated).
term_screen_text :: proc(t: ^Term_View) -> string {
	if t == nil || t.gt == nil do return ""
	text := rs_screen_text(t.rs, t.it, t.cells, t.gt)
	t.changed = true // render state was consumed here; redraw
	return text
}

// The same for any terminal (the core's, in tests), through a render state of its own.
gt_screen_text :: proc(gt: gh.Terminal) -> string {
	if gt == nil do return ""
	rs: gh.Render_State
	it: gh.Row_Iterator
	cells: gh.Row_Cells
	gh.render_state_new(nil, &rs)
	gh.render_state_row_iterator_new(nil, &it)
	gh.render_state_row_cells_new(nil, &cells)
	defer {
		gh.render_state_row_cells_free(cells)
		gh.render_state_row_iterator_free(it)
		gh.render_state_free(rs)
	}
	return rs_screen_text(rs, it, cells, gt)
}

@(private = "file")
rs_screen_text :: proc(rs: gh.Render_State, it: gh.Row_Iterator, cells: gh.Row_Cells, gt: gh.Terminal) -> string {
	it, cells := it, cells
	gh.render_state_update(rs, gt)
	b := strings.builder_make(context.temp_allocator)
	gh.render_state_get(rs, .Row_Iterator, &it)
	for gh.render_state_row_iterator_next(it) {
		gh.render_state_row_get(it, .Cells, &cells)
		for gh.render_state_row_cells_next(cells) {
			raw: gh.Cell
			gh.render_state_row_cells_get(cells, .Raw, &raw)
			wide: gh.Cell_Wide
			gh.cell_get(raw, .Wide, &wide)
			if wide == .Spacer_Tail do continue
			n: u32
			gh.render_state_row_cells_get(cells, .Graphemes_Len, &n)
			if n == 0 || n > 16 {
				strings.write_byte(&b, ' ')
				continue
			}
			buf: [16]u32
			gh.render_state_row_cells_get(cells, .Graphemes_Buf, &buf[0])
			for i in 0 ..< n do strings.write_rune(&b, rune(buf[i]))
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

@(private = "file")
send :: proc(e: sapp.Event) {
	ev := e
	if e.mouse_button == .LEFT && e.type == .MOUSE_DOWN do autotest.left_down = true
	if e.mouse_button == .LEFT && e.type == .MOUSE_UP do autotest.left_down = false
	event(&ev)
}

// The sweep command: across element NAME INDEX's box at mid height, each point
// moved to twice with a layout after each (a frame): the second must leave
// the hover as the first did. The box is taken once, before the first move.
@(private = "file")
sweep_hover :: proc(name: string, index: u32, steps: int) {
	_ = ui_layout(sapp.widthf(), sapp.heightf())
	d := clay.GetElementData(clay.ID(name, index))
	if !d.found {
		script_fail("no element", name, index)
		return
	}
	b := d.boundingBox
	y := b.y + b.height / 2
	flips := 0
	for i in 0 ..< steps {
		x := b.x + 1 + (b.width - 2) * f32(i) / f32(max(steps - 1, 1))
		send({type = .MOUSE_MOVE, mouse_x = x, mouse_y = y})
		_ = ui_layout(sapp.widthf(), sapp.heightf())
		first := fmt.tprintf("%v %v", reflect.union_variant_typeid(ui_hover), ui_hover)
		send({type = .MOUSE_MOVE, mouse_x = x, mouse_y = y})
		_ = ui_layout(sapp.widthf(), sapp.heightf())
		again := fmt.tprintf("%v %v", reflect.union_variant_typeid(ui_hover), ui_hover)
		if first != again {
			flips += 1
			if flips <= 5 do log(fmt.tprintf("hover flips at x=%.0f: %s -> %s", x / app.dpi, first, again))
		}
	}
	app.redraw = true
	autotest.asserts += 1
	if flips == 0 do log("assert ok: sweep", name, index, "steady at", steps, "points")
	else do script_fail(fmt.tprintf("ASSERT FAILED sweep %s %d: the hover flips at %d of %d points", name, index, flips, steps))
}

@(private = "file")
key_event :: proc(name: string, mods: u32) {
	kc := sapp.Keycode.INVALID
	ch: u32 = 0
	switch name {
	case "enter": kc = .ENTER
	case "tab": kc = .TAB
	case "backspace": kc = .BACKSPACE
	case "escape": kc = .ESCAPE
	case "up": kc = .UP
	case "down": kc = .DOWN
	case "left": kc = .LEFT
	case "right": kc = .RIGHT
	case "pageup": kc = .PAGE_UP
	case "pagedown": kc = .PAGE_DOWN
	case "home": kc = .HOME
	case "end": kc = .END
	case "space": kc, ch = .SPACE, ' '
	case "comma": kc, ch = .COMMA, ','
	case "slash": kc, ch = .SLASH, '/'
	case "period": kc, ch = .PERIOD, '.'
	case "f2": kc = .F2
	case "lcmd": kc = .LEFT_SUPER // ⌘ alone (pressed and let go)
	// a modifier alone, punctuation, function keys (browser-keys.txt)
	case "shift": kc = .LEFT_SHIFT
	case "rshift": kc = .RIGHT_SHIFT
	case "semicolon": kc, ch = .SEMICOLON, ';'
	case "quote": kc, ch = .APOSTROPHE, '\''
	case "lbracket": kc, ch = .LEFT_BRACKET, '['
	case "rbracket": kc, ch = .RIGHT_BRACKET, ']'
	case "backslash": kc, ch = .BACKSLASH, '\\'
	case "equal": kc, ch = .EQUAL, '='
	case "minus": kc, ch = .MINUS, '-'
	case "grave": kc, ch = .GRAVE_ACCENT, '`'
	case "f1": kc = .F1
	case "f5": kc = .F5
	case "f12": kc = .F12
	case "delete": kc = .DELETE
	case:
		if len(name) == 1 {
			r := name[0]
			switch {
			case r >= 'a' && r <= 'z': kc, ch = sapp.Keycode(int(sapp.Keycode.A) + int(r - 'a')), u32(r)
			case r >= '0' && r <= '9': kc, ch = sapp.Keycode(int(sapp.Keycode._0) + int(r - '0')), u32(r)
			}
		}
	}
	send({type = .KEY_DOWN, key_code = kc, modifiers = mods})
	// Cocoa sends the control character / symbol as CHAR too; mimic that.
	if ch != 0 {
		if mods & sapp.MODIFIER_CTRL != 0 && ch >= 'a' && ch <= 'z' do ch = ch - 'a' + 1
		send({type = .CHAR, char_code = ch, modifiers = mods})
	} else if kc == .ENTER {
		send({type = .CHAR, char_code = 13, modifiers = mods})
	}
	send({type = .KEY_UP, key_code = kc, modifiers = mods})
}

@(private = "file")
type_text :: proc(s: string) {
	for r in s {
		kc := sapp.Keycode.INVALID
		mods: u32 = 0
		switch {
		case r >= 'a' && r <= 'z': kc = sapp.Keycode(int(sapp.Keycode.A) + int(r - 'a'))
		case r >= 'A' && r <= 'Z': kc, mods = sapp.Keycode(int(sapp.Keycode.A) + int(r - 'A')), sapp.MODIFIER_SHIFT
		case r >= '0' && r <= '9': kc = sapp.Keycode(int(sapp.Keycode._0) + int(r - '0'))
		case r == ' ': kc = .SPACE
		case r == '.': kc = .PERIOD
		case r == ',': kc = .COMMA
		}
		send({type = .KEY_DOWN, key_code = kc, modifiers = mods})
		if r > 0xFFFF { // as Cocoa does: UTF-16 surrogate pair
			v := u32(r) - 0x10000
			send({type = .CHAR, char_code = 0xD800 + (v >> 10), modifiers = mods})
			send({type = .CHAR, char_code = 0xDC00 + (v & 0x3FF), modifiers = mods})
		} else {
			send({type = .CHAR, char_code = u32(r), modifiers = mods})
		}
		send({type = .KEY_UP, key_code = kc, modifiers = mods})
	}
}

@(private = "file")
num :: proc(s: string) -> f32 {
	v, _ := strconv.parse_f32(s)
	return v
}

// Runs script lines until one has to wait. Called once per frame.
// clickid's and rclickid's INDEX: a number (default 0), or @PATH for a drawn Files or Settings
// row by its path's end (files_drawn_slot). A path no row has fails the script.
script_index :: proc(args: []string) -> (u32, bool) {
	if len(args) < 2 do return 0, true
	if strings.has_prefix(args[1], "@") {
		slot := files_drawn_slot(args[1][1:])
		if slot < 0 do return 0, false // the caller tries again (script_retry), then fails
		return u32(slot), true
	}
	return u32(num(args[1])), true
}

autotest_step :: proc() {
	at := &autotest
	if !core.autotest_active do return
	if !at.started {
		// sokol activates the app at launch: hand focus straight back so the
		// user's keystrokes stay in their app (real input is dropped anyway)
		at.started = true
		app_deactivate()
	}
	autotest_push_facts()
	now := time.tick_now()
	// the replica against the core's State, between steps too (what terminals and timers did)
	if time.tick_diff(at.replica_checked, now) >= 200 * time.Millisecond do autotest_check_replica()
	if at.pending_shot != "" do app.redraw = true // keep presenting while raised
	if time.tick_diff(at.wait_until, now) < 0 {
		// a shot: once the raised window has drawn SHOT_FRAMES frames (and SHOT_MIN passed), not the
		// whole second wait_until allows
		shot_ready := at.pending_shot != "" && app.frames_drawn >= at.shot_drawn + SHOT_FRAMES && time.tick_diff(at.shot_at, now) >= SHOT_MIN
		if !shot_ready do return
	}
	if at.pending_shot != "" {
		// window was brought forward for this shot; frames have redrawn since
		png := fmt.tprintf("build/shots/%s.png", at.pending_shot)
		os.make_directory_all(filepath.dir(png))
		window_capture(png)
		_ = os.write_entire_file(fmt.tprintf("build/%s.txt", at.pending_shot), transmute([]u8)screen_text())
		window_send_back()
		log("captured", at.pending_shot)
		at.pending_shot = ""
	}
	if at.wait_exit {
		t := core.active_term()
		if t != nil && t.running && time.tick_diff(at.deadline, now) < 0 do return
		log("child exited:", t == nil || !t.running)
		at.wait_exit = false
	}
	if at.wait_request != 0 { 	// autotest_on_event clears it
		if time.tick_diff(at.wait_request_deadline, now) <= 0 do return
		script_fail(fmt.tprintf("TIMEOUT waiting for request %d to finish (%v)", at.wait_request, script_finish_timeout))
		at.wait_request = 0
	}
	if at.wait_state[0] != "" {
		got := core.json_path(script_state_json(), at.wait_state[0])
		// a separate core: the delta that reached it came after this frame's layout, so one more
		// frame lays it out (the panes' rects) before the next line reads it, as in process
		if got == at.wait_state[1] && client_separate() && (at.wait_state_at == 0 || app.frames_drawn <= at.wait_state_at) {
			if at.wait_state_at == 0 do at.wait_state_at = app.frames_drawn
			app.redraw = true
			return
		}
		if got == at.wait_state[1] {
			log("state reached:", at.wait_state[0], "=", got)
		} else if time.tick_diff(at.deadline, now) > 0 {
			script_fail(fmt.tprintf("TIMEOUT waiting for %s = %q (got %q)", at.wait_state[0], at.wait_state[1], got))
		} else {
			return
		}
		delete(at.wait_state[0])
		delete(at.wait_state[1])
		at.wait_state, at.wait_state_at = {}, 0
	}
	if at.waiting_for != "" {
		if strings.contains(screen_text(), at.waiting_for) {
			log("found", at.waiting_for)
			at.waiting_for = ""
		} else if time.tick_diff(at.deadline, now) > 0 {
			msg := strings.concatenate({"TIMEOUT waiting for ", at.waiting_for}, context.temp_allocator)
			at.waiting_for = ""
			script_fail(msg)
			if !core.autotest_active do return
		} else {
			return
		}
	}
	if !browser_wait_done(proc(msg: string) {script_fail(msg)}) do return // a web_* wait (browser.odin)
	if !app_wait_done(proc(msg: string) {script_fail(msg)}) do return // an app_* wait (app_tab.odin)
	for at.next < len(at.lines) {
		idx := at.next
		line := strings.trim_space(at.lines[at.next])
		at.next += 1
		if line == "" || line[0] == '#' do continue
		autotest_push_facts() // what the step before this one changed in the window (a key, a mode)
		// a separate core: the step starts once the core ran what the steps before it sent (a key's
		// or a click's command) and the window took its answers (the delta, a link opened, a file
		// revealed), as in process, where a command runs before the next frame
		if client_separate() && idx != at.retry_line do client_barrier()
		autotest_check_replica() // after the step before this one (design §10.2, M3-F)
		cmd, _, rest := strings.partition(line, " ")
		// and each shown terminal's copy (M3-H): once per step, not on every retry of it
		if idx != at.retry_line do autotest_check_terms()
		args := strings.fields(rest, context.temp_allocator)
		if idx != at.retry_line {
			log(line)
			at.elem_until = {}
			if at.step_file != "" do script_write_step(idx, line)
		}
		at.retry_line = -1
		if script_is_check(cmd) {
			ok, msg := script_check(cmd, rest, args)
			if !ok && at.eventually_on && time.tick_diff(at.eventually_until, time.tick_now()) < 0 {
				at.retry_line, at.next = idx, idx // again next frame (drawn: some checks read the last layout)
				app.redraw = true
				return
			}
			if at.audit && at.audit_wait >= 0 {
				log(fmt.tprintf("AUDIT C %d %d %s", at.audit_wait + 1, at.audit_k, ok ? "pass" : "fail"))
				at.audit_k += 1
			}
			at.asserts += 1
			if ok do log(msg)
			else do script_fail(msg)
			continue
		}
		if cmd != "eventually" do at.eventually_on = false
		if at.audit do script_audit(idx, cmd)
		// an element-addressed line reads the last layout: one drawn after the last input (not
		// the same click again right after it: two clickid lines are a double-click)
		// a separate core: the step's barrier (above) brought that input's delta; then a frame
		// drawn after it, as in process where it ran at once
		if script_reads_layout(cmd) && client_separate() && !at.input_synced && line != at.input_line {
			at.input_synced, at.input_drawn = true, app.frames_drawn
			app.redraw = true
			at.retry_line, at.next = idx, idx
			return
		}
		if script_reads_layout(cmd) && app.frames_drawn <= at.input_drawn && line != at.input_line {
			app.redraw = true
			at.retry_line, at.next = idx, idx
			return
		}
		if script_is_input(cmd) {
			at.input_synced = false
			at.input_drawn = app.frames_drawn
			delete(at.input_line)
			at.input_line = strings.clone(line)
		}
		switch cmd {
		case "waitresult": // waitresult MS PATH VALUE: the `command` line just before, run again until its result has VALUE at PATH
			ms_s, _, pv := strings.partition(rest, " ")
			path, _, want := strings.partition(strings.trim_space(pv), " ")
			want = expand_vars(want)
			got := core.json_path(at.last_result, path)
			prev := at.command_idx >= 0 ? strings.trim_space(at.lines[at.command_idx]) : ""
			_, _, prev_json := strings.partition(prev, " ")
			type := core.json_path(expand_vars(prev_json), "type")
			if got == want {
				log("result reached:", path, "=", got)
				at.wr_idx = -1
				continue
			}
			if !script_read_only(type) {
				script_fail(fmt.tprintf("waitresult: %q is not a read-only command (it would run again)", type))
				continue
			}
			now2 := time.tick_now()
			if at.wr_idx != idx {
				at.wr_idx = idx
				at.wr_until = time.tick_add(now2, time.Duration(num(ms_s)) * time.Millisecond)
			}
			if time.tick_diff(at.wr_until, now2) >= 0 {
				script_fail(fmt.tprintf("TIMEOUT waiting for %s = %q in the result (got %q)", path, want, got))
				at.wr_idx = -1
				continue
			}
			at.retry_line, at.next = at.command_idx, at.command_idx // the command again, then this line
			at.wait_until = time.tick_add(now2, 100 * time.Millisecond)
			return
		case "eventually": // eventually [MS]: the checks right after this line may take up to MS (10 s)
			at.eventually_on = true
			ms: f32 = 10000
			if len(args) > 0 do ms = num(args[0])
			at.eventually_until = time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
		case "wait":
			// from now, not the frame's start: a step before it (a shot) may have taken a second
			at.wait_until = time.tick_add(time.tick_now(), time.Duration(num(rest)) * time.Millisecond)
			return
		case "waitfor":
			text := rest
			ms: f32 = 30000
			if i := strings.last_index_byte(rest, ' '); i > 0 {
				if v, ok := strconv.parse_f32(rest[i + 1:]); ok {
					text, ms = rest[:i], v
				}
			}
			at.waiting_for = strings.clone(text)
			at.deadline = time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
			return
		case "waitstate": // waitstate MS PATH VALUE…: until the state JSON has VALUE at PATH
			ms_s, _, pv := strings.partition(rest, " ")
			path, _, want := strings.partition(strings.trim_space(pv), " ")
			at.wait_state = {strings.clone(path), strings.clone(expand_vars(want))}
			at.deadline = time.tick_add(time.tick_now(), time.Duration(num(ms_s)) * time.Millisecond)
			return
		case "jobs_clock": // jobs_clock SECONDS: the jobs' clock moves on, then a due check
			if client_separate() do script_on_core(line) // the scheduler is the core's
			else do core.jobs_clock_advance(i64(num(rest)))
		case "window_active": // window_active on|off: as if Deckhand were in front or behind
			app.window_active = strings.trim_space(rest) == "on"
		case "detach_window": // the window plays gone (M4's no-window cases): the core answers no_window for its tabs
			if client_separate() do script_on_core(line) // the core plays it: the script's lines still go over the link
			else do client_detach() // client.odin
		case "attach_window": // ...and comes back: the whole state again, its pages and apps as they were
			if client_separate() do script_on_core(line)
			else do client_reattach()
		case "jobs_ui": // jobs_ui OPEN_ID [limits]: open a row (and the limits) on the Jobs tab
			jobs_ui_set(len(args) > 0 && args[0] != "-" ? args[0] : "", len(args) > 1 && args[1] == "limits")
		case "replace_in_file": // replace_in_file PATH OLD|NEW: an outside edit (another editor, an agent)
			path, _, pair := strings.partition(strings.trim_space(expand_vars(rest)), " ")
			old, _, new := strings.partition(pair, "|")
			data, _ := os.read_entire_file(path, context.temp_allocator)
			out, n := strings.replace(string(data), old, new, 1, context.temp_allocator)
			if !n do script_fail("replace_in_file: not found:", old)
			else do _ = os.write_entire_file(path, transmute([]u8)out)
		case "waitexit":
			ms: f32 = 60000
			if len(args) > 0 do ms = num(args[0])
			at.wait_exit = true
			at.deadline = time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
			return
		case "hover":
			args := strings.fields(expand_vars(rest), context.temp_allocator)
			eidx, iok := script_index(args)
			if !iok {
				if script_retry(idx) do return
				script_fail("no drawn row ends with", args[1][1:])
				continue
			}
			d := clay.GetElementData(clay.ID(args[0], eidx))
			if !d.found {
				if script_retry(idx) do return
				log("no element", rest)
				continue
			}
			b := d.boundingBox
			held: u32 = tab_drag.tab != 0 ? sapp.MODIFIER_LMB : 0 // a held dragtab's button is still down
			send({type = .MOUSE_MOVE, mouse_x = b.x + b.width / 2, mouse_y = b.y + b.height / 2, modifiers = held})
		case "sweep":
			sweep_hover(args[0], u32(num(args[1])), int(num(args[2])))
		case "clickid":
			args := strings.fields(expand_vars(rest), context.temp_allocator)
			eidx, iok := script_index(args)
			if !iok {
				if script_retry(idx) do return
				script_fail("no drawn row ends with", args[1][1:])
				continue
			}
			d := clay.GetElementData(clay.ID(args[0], eidx))
			if !d.found {
				if script_retry(idx) do return
				log("no element", rest)
				continue
			}
			b := d.boundingBox
			x, y := b.x + b.width / 2, b.y + b.height / 2
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
		case "rclickid":
			eidx, iok := script_index(args)
			if !iok {
				if script_retry(idx) do return
				script_fail("no drawn row ends with", args[1][1:])
				continue
			}
			d := clay.GetElementData(clay.ID(args[0], eidx))
			if !d.found {
				if script_retry(idx) do return
				script_fail("no element", rest)
				continue
			}
			b := d.boundingBox
			x, y := b.x + b.width / 2, b.y + b.height / 2
			send({type = .MOUSE_DOWN, mouse_button = .RIGHT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .RIGHT, mouse_x = x, mouse_y = y})
		case "clickmd":
			x, y, ok := md_piece_point(rest)
			if !ok {
				if script_retry(idx) do return
				script_fail("no preview text", rest)
				continue
			}
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
		case "clickmenu":
			// left click the open context menu's row labelled TEXT (as drawn last frame)
			if !menu.open {
				if script_retry(idx) do return
				script_fail("ASSERT FAILED clickmenu: no menu is open, want", rest)
				continue
			}
			row := -1
			for it, i in menu_items() do if !it.sep && !it.note && it.label == rest {row = i; break}
			d := clay.GetElementData(clay.ID("menurow", u32(max(row, 0))))
			if row < 0 || !d.found {
				if script_retry(idx) do return
				script_fail(fmt.tprintf("ASSERT FAILED clickmenu: no row %q in %s", rest, menu_rows_text()))
				continue
			}
			b := d.boundingBox
			x, y := b.x + b.width / 2, b.y + b.height / 2
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
		case "revealed_clear":
			delete(autotest.revealed)
			autotest.revealed = ""
			delete(core.fs_model.revealed)
			core.fs_model.revealed = ""
		case "toast_clear":
			toast_clear()
		case "clipboard_clear":
			delete(autotest.clipboard)
			autotest.clipboard = ""
		case "dragid":
			// a left drag from the centre of element FROM (index) to the centre of TO
			args := strings.fields(expand_vars(rest), context.temp_allocator)
			from := clay.GetElementData(clay.ID(args[0], u32(num(args[1]))))
			to := clay.GetElementData(clay.ID(args[2]))
			if !from.found || !to.found {
				if script_retry(idx) do return
				script_fail("no element", rest)
				continue
			}
			x1, y1 := from.boundingBox.x + from.boundingBox.width / 2, from.boundingBox.y + from.boundingBox.height / 2
			x2, y2 := to.boundingBox.x + to.boundingBox.width / 2, to.boundingBox.y + to.boundingBox.height / 2
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x1, mouse_y = y1})
			for i in 1 ..= 8 {
				f := f32(i) / 8
				send({type = .MOUSE_MOVE, mouse_x = x1 + (x2 - x1) * f, mouse_y = y1 + (y2 - y1) * f, modifiers = sapp.MODIFIER_LMB})
			}
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x2, mouse_y = y2})
		case "dragtab":
			x1, y1, x2, y2, ok := script_tab_drag_points(strings.fields(expand_vars(rest), context.temp_allocator))
			if !ok {
				if script_retry(idx) do return
				script_fail("dragtab: no such tab or place", rest)
				continue
			}
			send({type = .MOUSE_MOVE, mouse_x = x1, mouse_y = y1})
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x1, mouse_y = y1})
			for i in 1 ..= 8 {
				f := f32(i) / 8
				send({type = .MOUSE_MOVE, mouse_x = x1 + (x2 - x1) * f, mouse_y = y1 + (y2 - y1) * f, modifiers = sapp.MODIFIER_LMB})
			}
			switch args[len(args) - 1] {
			case "esc": key_event("escape", 0)
			case "hold": continue // the button stays down (a shot of the indicator; `key escape` ends it)
			}
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x2, mouse_y = y2})
		case "files_time":
			// how long the Files tree takes to lay out N frames while scrolling by DY each (logical px)
			n, dy := int(num(args[0])), num(args[1])
			t0 := time.tick_now()
			for _ in 0 ..< n {
				core.files_ui.scroll += dy
				w, h := sapp.widthf(), sapp.heightf()
				ui_layout(w, h)
			}
			ms := time.duration_milliseconds(time.tick_since(t0))
			log(fmt.tprintf("FILES layout while scrolling: %d frames in %.1f ms (%.2f ms per frame), %d rows", n, ms, ms / f64(n), len(core.files_ui.rows)))
			app.redraw = true
		case "drop":
			paths := make([dynamic]string, context.temp_allocator)
			for a in args[1:] do append(&paths, expand_vars(a))
			d := clay.GetElementData(clay.ID(args[0]))
			if !d.found {
				script_fail("no element", args[0])
				continue
			}
			b := d.boundingBox
			sidebar_drop(paths[:], b.x + b.width / 2, b.y + b.height / 2)
		case "pick_folder":
			delete(at.fake_folder)
			at.fake_folder = strings.clone(expand_vars(rest))
		case "divider":
			if args[0] == "pane" {
				if !script_pane_divider(args[1:]) do script_fail("divider pane: no divider after pane", args[1])
				continue
			}
			which := int(num(args[0]))
			l, r := column_widths()
			x := which == 0 ? l * app.dpi : ui_win_w - r * app.dpi
			if d := clay.GetElementData(clay.ID("right")); which == 1 && d.found do x = d.boundingBox.x // beside a pinned drawer too
			if which == 2 { 	// the agent drawer's left edge, over Atlas's terminal
				d := clay.GetElementData(clay.ID("drawer"))
				if !d.found {
					script_fail("divider 2: the drawer is not shown")
					continue
				}
				x = d.boundingBox.x
			}
			y := px(TAB_STRIP_H) + 200 * app.dpi
			if len(args) > 2 && args[1] == "clicks" {
				for _ in 0 ..< int(num(args[2])) {
					send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
					send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
				}
				continue
			}
			dx := num(args[1]) * app.dpi
			send({type = .MOUSE_MOVE, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			for i in 1 ..= 8 do send({type = .MOUSE_MOVE, mouse_x = x + dx * f32(i) / 8, mouse_y = y, modifiers = sapp.MODIFIER_LMB})
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x + dx, mouse_y = y})
		case "state":
			t := core.active_term()
			if t == nil do continue
			mt: gh.Mouse_Tracking
			gh.terminal_get(t.gt, .Mouse_Tracking, &mt)
			screen: gh.Terminal_Screen
			gh.terminal_get(t.gt, .Active_Screen, &screen)
			log(fmt.tprintf("mouse_tracking=%v sgr_1006=%v bracketed_paste_2004=%v focus_1004=%v sync_2026=%v color_scheme_2031=%v screen=%v cols=%d rows=%d", mt, core.mode_on(t, 1006), core.mode_on(t, 2004), core.mode_on(t, 1004), core.mode_on(t, 2026), core.mode_on(t, 2031), screen, t.cols, t.rows))
		case "type":
			type_text(rest)
		case "key":
			mods: u32
			for a in args[1:] {
				switch a {
				case "shift": mods |= sapp.MODIFIER_SHIFT
				case "ctrl": mods |= sapp.MODIFIER_CTRL
				case "alt": mods |= sapp.MODIFIER_ALT
				case "cmd": mods |= sapp.MODIFIER_SUPER
				}
			}
			key_event(args[0], mods)
		case "paste":
			s, _ := strings.replace_all(rest, `\n`, "\n", context.temp_allocator)
			autotest_paste_set(s)
			send({type = .CLIPBOARD_PASTED})
		case "scroll":
			send({type = .MOUSE_SCROLL, scroll_y = num(args[0]), mouse_x = num(args[1]) * app.dpi, mouse_y = num(args[2]) * app.dpi})
		case "click":
			x, y := num(args[0]) * app.dpi, num(args[1]) * app.dpi
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
		case "drag":
			x1, y1, x2, y2 := num(args[0]) * app.dpi, num(args[1]) * app.dpi, num(args[2]) * app.dpi, num(args[3]) * app.dpi
			m: u32 = len(args) > 4 && args[4] == "shift" ? sapp.MODIFIER_SHIFT : 0
			held: u32 = args[len(args) - 1] == "held" ? sapp.MODIFIER_LMB : 0
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x1, mouse_y = y1, modifiers = m})
			for i in 1 ..= 8 {
				f := f32(i) / 8
				send({type = .MOUSE_MOVE, mouse_x = x1 + (x2 - x1) * f, mouse_y = y1 + (y2 - y1) * f, modifiers = m | held})
			}
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x2, mouse_y = y2, modifiers = m})
		case "clicks":
			x, y := num(args[1]) * app.dpi, num(args[2]) * app.dpi
			for _ in 0 ..< int(num(args[0])) {
				send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
				send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			}
		case "clickcell":
			t := active_view()
			if t == nil {
				script_fail("clickcell: no terminal")
				continue
			}
			cell := proc(t: ^Term_View, c, r: string) -> (f32, f32) {
				return t.x + term_pad() + (num(c) + 0.5) * font.cell_w, t.y + term_pad() + (num(r) + 0.5) * font.cell_h
			}
			x, y := cell(t, args[1], args[2])
			n := int(num(args[0]))
			for i in 0 ..< n {
				send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
				if i < n - 1 do send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			}
			ux, uy := x, y
			if len(args) > 4 {
				ux, uy = cell(t, args[3], args[4])
				send({type = .MOUSE_MOVE, mouse_x = ux, mouse_y = uy, modifiers = sapp.MODIFIER_LMB})
			}
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = ux, mouse_y = uy})
		case "mousecell":
			// mousecell down|move|up COL ROW [shift]: one step of a press held
			// across frames (a drag the frame loop draws in between)
			t := active_view()
			for a in args[3:] do if strings.has_prefix(a, "pane=") do t = script_pane_term(a[5:])
			if t == nil {
				script_fail("mousecell: no terminal")
				continue
			}
			x := t.x + term_pad() + (num(args[1]) + 0.5) * font.cell_w
			y := t.y + term_pad() + (num(args[2]) + 0.5) * font.cell_h
			m: u32
			for a in args[3:] {
				switch a {
				case "shift": m |= sapp.MODIFIER_SHIFT
				case "cmd":   m |= sapp.MODIFIER_SUPER
				case "ctrl":  m |= sapp.MODIFIER_CTRL
				}
			}
			switch args[0] {
			case "down": send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = m})
			case "move": send({type = .MOUSE_MOVE, mouse_x = x, mouse_y = y, modifiers = m | sapp.MODIFIER_LMB})
			case "up":   send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = m})
			case "hover": send({type = .MOUSE_MOVE, mouse_x = x, mouse_y = y, modifiers = m}) // no button
			case "click": // a press and release
				send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = m})
				send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y, modifiers = m})
			case "rclick":
				send({type = .MOUSE_DOWN, mouse_button = .RIGHT, mouse_x = x, mouse_y = y, modifiers = m})
				send({type = .MOUSE_UP, mouse_button = .RIGHT, mouse_x = x, mouse_y = y, modifiers = m})
			}
		case "clicktext":
			d := clay.GetElementData(clay.ID(args[1]))
			f, _, _ := focused_field()
			if !d.found || f == nil {
				script_fail("clicktext: no such field", args[1])
				continue
			}
			off := clamp(int(num(args[2])), 0, len(f.buf))
			x := d.boundingBox.x + text_width(tf_text(f)[:off], .UI)
			y := d.boundingBox.y + d.boundingBox.height / 2
			for _ in 0 ..< int(num(args[0])) {
				send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
				send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			}
		case "beeps":
			n := test_beeps()
			log(fmt.tprintf("beeps: %d (input context: %v)", n, test_has_input_context()))
			if len(args) > 0 {
				at.asserts += 1
				if fmt.tprint(n) == args[0] do log("assert ok: beeps =", n)
				else do script_fail(fmt.tprintf("ASSERT FAILED beeps: got %d, want %s", n, args[0]))
			}
		case "panels":
			n := test_panels()
			log(fmt.tprintf("panels: %d", n))
			if len(args) > 0 {
				at.asserts += 1
				if fmt.tprint(n) == args[0] do log("assert ok: panels =", n)
				else do script_fail(fmt.tprintf("ASSERT FAILED panels: got %d, want %s", n, args[0]))
			}
		case "ime_press":
			head, _, tail := strings.partition(rest, " -- ")
			ha := strings.fields(head, context.temp_allocator)
			chars := ha[1]
			switch chars {
			case "enter": chars = "\r"
			case "-":     chars = ""
			}
			alt, repeat := false, false
			for a in ha[2:] {
				if a == "alt" do alt = true
				if a == "repeat" do repeat = true
			}
			ops, _ := strings.join(strings.fields(tail, context.temp_allocator), "\t", context.temp_allocator)
			at.injecting = true
			test_ime(3, chars, int(num(ha[0])), alt, repeat, ops)
			at.injecting = false
			log("marked:", fmt.tprintf("%q", ime.marked))
		case "ime_mark", "ime_commit":
			at.injecting = true
			test_ime(cmd == "ime_mark" ? 0 : 1, rest)
			at.injecting = false
			log("marked:", fmt.tprintf("%q", ime.marked))
		case "ime_key":
			text := len(args) > 1 ? args[1] : ""
			switch text {
			case "enter":     text = "\r"
			case "backspace": text = "\x7f"
			case "tab":       text = "\t"
			case "escape":    text = "\x1b"
			case "space":     text = " "
			case "left":      text = "\uF702"
			case "right":     text = "\uF703"
			case "up":        text = "\uF700"
			case "down":      text = "\uF701"
			case "delete":    text = "\uF728" // forward delete (fn+⌫)
			}
			flags := 0
			for a in args[min(2, len(args)):] {
				switch a {
				case "alt":    flags |= 1
				case "repeat": flags |= 2
				case "cmd":    flags |= 4
				case "ctrl":   flags |= 8
				case "shift":  flags |= 16
				}
			}
			at.injecting = true
			test_ime(2, text, int(num(args[0])), flags = flags)
			at.injecting = false
			log("marked:", fmt.tprintf("%q", ime.marked))
		case "system_appearance":
			// as if the OS switched (the platform's KVO callback path)
			on_system_appearance(args[0] == "light")
			script_drain()
		case "lights":
			x, y := test_light()
			log(fmt.tprintf("traffic lights: close button centre %.1f,%.1f; top bar centre y %.1f", x, y, f32(TAB_STRIP_H) / 2))
		case "copy":
			key_event("c", sapp.MODIFIER_SUPER)
			log("clipboard:", fmt.tprintf("%q", clipboard_text()))
		case "resize":
			window_set_content_size(num(args[0]), num(args[1]))
		case "shot":
			// An occluded window may not be composited: bring it forward
			// without taking keyboard focus, redraw, capture next step.
			window_raise_without_focus()
			app.redraw = true
			if t := active_view(); t != nil do t.changed = true
			at.pending_shot = strings.clone(args[0])
			at.shot_drawn, at.shot_at = app.frames_drawn, now
			at.wait_until = time.tick_add(now, 1000 * time.Millisecond) // at most
			return
		case "dump":
			_ = os.write_entire_file(fmt.tprintf("build/%s.txt", args[0]), transmute([]u8)screen_text())
		case "cpu_begin":
			at.cpu_wall = now
			at.cpu_start = cpu_seconds()
			at.cpu_core_start = client_separate() ? pid_cpu_seconds(client.core_pid) : 0
			at.cpu_frames = app.frames_drawn
			at.cpu_bytes = total_bytes_in()
			at.cpu_calls = core.app_frames_called
			at.cpu_checks = at.terms_check_cpu
		case "cpu_end":
			wall := time.duration_seconds(time.tick_diff(at.cpu_wall, now))
			cpu := cpu_seconds() - at.cpu_start - (at.terms_check_cpu - at.cpu_checks) // without the terminal copies' checks (test mode's)
			calls := core.app_frames_called - at.cpu_calls
			log(fmt.tprintf("CPU %s: %.1f%% over %.1fs, %d frames drawn, %d frame callbacks (%.1f/s), %d pty bytes", rest, 100 * cpu / wall, wall, app.frames_drawn - at.cpu_frames, calls, f64(calls) / wall, total_bytes_in() - at.cpu_bytes))
			if client_separate() { // per process: the window above, the core here (benchmarks: term-bench.sh)
				ccpu := pid_cpu_seconds(client.core_pid) - at.cpu_core_start
				log(fmt.tprintf("CPU %s core: %.1f%% over %.1fs (%.2f CPU-s; window %.2f CPU-s); replies waited at most %.0f ms, %d gave up", rest, 100 * ccpu / wall, wall, ccpu, cpu, time.duration_milliseconds(client_wait_max), client_wait_gave_up))
			}
		case "atlas":
			size, glyphs, rasterised, evictions, runs := font_stats()
			log(fmt.tprintf("atlas %dx%d px (%d KB), %d glyphs cached, %d rasterised, %d evictions, %d runs, mono %q %.0fpx cell %.0fx%.0f", size, size, int(size) * int(size) * 4 / 1024, glyphs, rasterised, evictions, runs, font.sets[.Mono].family, font.sets[.Mono].px, font.cell_w, font.cell_h))
		case "window":
			// as if the window went to the background or came to the front
			// (sokol's UNFOCUSED/FOCUSED; quiet test mode never gets them)
			send({type = args[0] == "back" ? .UNFOCUSED : .FOCUSED})
			script_drain()
		case "deactivate":
			app_deactivate()
		case "minimize":
			window_minimize()
		case "restore":
			window_restore()
		case "hide":
			app_hide()
		case "unhide":
			app_unhide()
		case "frames":
			at.frames_off = len(args) > 0 && args[0] == "off"
			at.frames_back = time.tick_add(time.tick_now(), FRAMES_OFF_MAX)
		case "core_loop":
			l := core.core_loop
			log(fmt.tprintf("core_loop timer_ticks %d skipped %d frames_called %d frames_drawn %d", l.timer_ticks, l.skipped, core.app_frames_called, app.frames_drawn))
		case "menu":
			it := menubar_find(args[0])
			if it == nil || it.native != .None {
				script_fail("menu: no such item (or AppKit's own):", args[0])
				continue
			}
			if on, _ := menubar_state(menubar_tag(it)); !on {
				script_fail("menu: disabled:", args[0])
				continue
			}
			at.injecting = true
			menubar_run(it)
			at.injecting = false
		case "menu_key":
			chars := args[1]
			switch chars {
			case "backspace": chars = "\x7f"
			case "left":      chars = "\uF702"
			case "right":     chars = "\uF703"
			case "up":        chars = "\uF700"
			case "down":      chars = "\uF701"
			}
			mods: u64
			want := ""
			key_window := true
			for a in args[2:] {
				switch a {
				case "cmd":   mods |= NS_COMMAND
				case "shift": mods |= NS_SHIFT
				case "alt":   mods |= NS_OPTION
				case "ctrl":  mods |= NS_CONTROL
				case "menu", "view": want = a
				case "notkey": key_window = false
				}
			}
			at.injecting = true
			took := test_menu_key(chars, mods, int(num(args[0])), key_window)
			at.injecting = false
			script_drain()
			got := took ? "menu" : "view"
			log("key went through:", got)
			if want != "" {
				at.asserts += 1
				if got == want do log("assert ok: key", rest)
				else do script_fail(fmt.tprintf("ASSERT FAILED menu_key %s: went to the %s", rest, got))
			}
		case "menubar_dump":
			path := fmt.tprintf("build/%s.txt", args[0])
			os.make_directory_all(filepath.dir(path))
			_ = os.write_entire_file(path, transmute([]u8)test_menu_dump())
			log("menu bar written to", path)
		case "command", "ui_command", "control_command", "pi_command", "pi_command_bg": // control_command: as an agent (Atlas, the CLI); pi_command: as the pi tab of the session on screen (its bridge); _bg: not waited for (await_bg)
			text := expand_vars(rest)
			c, err := core.parse_command(text, context.temp_allocator)
			if err != "" {
				script_fail("command parse error:", err)
				continue
			}
			at.command_idx = idx
			kind: core.Caller_Kind = cmd == "ui_command" ? .UI : cmd == "control_command" ? .Control : strings.has_prefix(cmd, "pi_") ? .Panel : .Script
			caller := core.Caller{kind = kind}
			if kind == .Panel do if cs := core.cur(); cs != nil do caller.tab_id = cs.tabs[0].id
			id, r, finished := script_command(c, caller)
			delete(at.last_result)
			at.last_result = strings.clone(core.result_json(r))
			if r.created_id != 0 do at.prev_created, at.last_created = at.last_created, r.created_id
			if r.confirm_token != "" {
				delete(at.last_token)
				at.last_token = strings.clone(r.confirm_token)
			}
			log("result", id, at.last_result)
			core.result_free(r)
			if r.pending && cmd == "pi_command_bg" {
				at.bg_request, at.bg_done = id, finished
				continue
			}
			if r.pending && !finished {
				at.wait_request = id
				at.wait_request_deadline = time.tick_add(time.tick_now(), script_finish_wait(c))
				return
			}
		case "await_bg": // await_bg MS: until pi_command_bg's command finished (its result: assert_finished)
			if at.bg_request == 0 {
				script_fail("await_bg: no pi_command_bg")
				continue
			}
			if !at.bg_done {
				if at.bg_deadline == {} do at.bg_deadline = time.tick_add(now, time.Duration(num(rest)) * time.Millisecond)
				if time.tick_diff(at.bg_deadline, now) > 0 {
					script_fail("TIMEOUT waiting for the pi_command_bg command")
					at.bg_request, at.bg_deadline = 0, {}
					continue
				}
				at.next -= 1 // this line again next frame
				return
			}
			at.bg_request, at.bg_deadline = 0, {}
		case "thread_command":
			c, err := core.parse_command(expand_vars(rest)) // heap: freed by the thread
			if err != "" {
				script_fail("command parse error:", err)
				continue
			}
			log("wakes so far:", app.wakes)
			pc := new_clone(c) // a Command is too big to pass by value
			thread.run_with_poly_data(pc, proc(pc: ^core.Command) {
				core.inbox_submit(pc^, {kind = .Control})
				core.command_free(pc^, context.allocator)
				free(pc)
			})
		case "wakes":
			log("wakes so far:", app.wakes)
		case "result_file": // result_file NAME: the last command's result to build/NAME.json
			_ = os.write_entire_file(fmt.tprintf("build/%s.json", args[0]), transmute([]u8)at.last_result)
		case "state_json":
			_ = os.write_entire_file(fmt.tprintf("build/%s.json", args[0]), transmute([]u8)script_state_json())
		case "screen_hashes": // screen_hashes: per terminal tab "[autotest] screen_hash <tab id> <held> <hash>" (snapshot.odin)
			if client_separate() { // the window's copies (the core's terminals are in its process)
				for id, v in term_views do if v.gt != nil {
					h, _ := core.screen_hash(v.gt)
					fmt.printfln("[autotest] screen_hash %d view %x", id, h)
				}
			}
			for id, x in core.terms {
				h, _ := core.screen_hash(x.gt)
				fmt.printfln("[autotest] screen_hash %d %d %x", id, x.pty.held, h)
			}
		case "quit", "quit_window":
			// a separate core: the window process ran core work on its replica (core.run_command)
			if core.replica_core_runs > 0 do script_fail("the window process ran", core.replica_core_runs, "core command(s) on its replica (see the log)")
			log(fmt.tprintf("done: %d asserts, %d failed; %d terminal copies checked", at.asserts, at.failures, at.terms_checked))
			core.app_quitting = true // the script ends the run: no confirmation
			if cmd == "quit" && client_separate() do script_core_quit()
			script_show_again()
			app_request_quit()
			core.autotest_active = false
			return
		case "web_open", "web_waitpaint", "web_title", "web_pixel", "web_click", "web_scroll", "web_js", "web_stats", "web_assert", "web_mouse", "web_keydown", "web_mark", "web_comment":
			if msg, ok := browser_script(cmd, args, rest); !ok do script_fail(msg)
			else do at.asserts += cmd == "web_title" || cmd == "web_pixel" || cmd == "web_assert" ? 1 : 0
			if browser_wait.kind != "" do return
		case "page_rclick", "page_menu", "page_crash", "page_assert":
			if msg, ok := page_script(cmd, args, expand_vars(rest)); !ok do script_fail(msg)
			else do at.asserts += cmd == "page_assert" ? 1 : 0
		case "act_assert", "act_clipboard":
			if msg, ok := act_script(cmd, args, rest); !ok do script_fail(msg)
			else do at.asserts += cmd == "act_assert" ? 1 : 0
		case "agent_assert":
			xr := expand_vars(rest) // $last, $tab, …
			if msg, ok := agent_script(cmd, strings.fields(xr, context.temp_allocator), xr); !ok do script_fail(msg)
			else do at.asserts += 1
		case "annot_move", "annot_drag", "annot_key", "annot_assert":
			if msg, ok := annot_script(cmd, args, rest); !ok do script_fail(msg)
			else do at.asserts += cmd == "annot_assert" ? 1 : 0
		case "app_open", "app_waitframe", "app_waitstatus", "app_waitlog", "assert_app_log", "assert_not_app_log", "assert_app_pixel", "app_square", "assert_app_moved", "app_mark", "app_waitring", "assert_app_surfaces", "assert_apps_freed", "app_click", "app_stats", "assert_app_dimmed", "app_keydown", "app_drag", "app_hover", "assert_app_hover", "assert_shot_pixel", "app_mouse", "app_leave", "app_display_fps", "assert_display_link":
			xr := expand_vars(rest) // $datadir, $tab, …
			app_last_finished = at.last_finished // assert_shot_pixel reads its data.path
			if msg, ok := app_script(cmd, strings.fields(xr, context.temp_allocator), xr); !ok do script_fail(msg)
			else do at.asserts += strings.has_prefix(cmd, "assert_") ? 1 : 0
			if app_wait.kind != "" do return
		case:
			log("unknown command", cmd)
		}
	}
}

// How a script command runs: the inbox's drain (a test may stand in for it, e.g. to have an
// app's reply processed before the drain returns).
script_drain: proc() = core.inbox_drain

// How long a script waits for a long-running command's finished result before it fails with
// TIMEOUT: this, or the command's own timeout_ms + 10 s when that is longer (script_finish_wait).
// It keeps a scene from hanging; a result that comes after the TIMEOUT is dropped.
script_finish_timeout := 120 * time.Second

// The wait for c's finished result: script_finish_timeout, or c's own timeout_ms + 10 s (so its
// own timeout error comes first) when that is longer.
script_finish_wait :: proc(c: core.Command) -> time.Duration {
	own: time.Duration
	#partial switch x in c {
	case core.App_Call:          own = time.Duration(x.timeout_ms) * time.Millisecond
	case core.Browser_Page_Wait: own = time.Duration(x.timeout_ms) * time.Millisecond
	case core.Claude_Wait_Idle:  own = time.Duration(x.timeout_ms) * time.Millisecond
	case core.Pi_Wait_Idle:      own = time.Duration(x.timeout_ms) * time.Millisecond
	}
	if own <= 0 do return script_finish_timeout
	return max(script_finish_timeout, own + 10 * time.Second)
}

// The window's facts (window_hooks.odin) reach the core before a step reads its State: a step's
// key or click changed them in this same tick, after the frame's push.
autotest_push_facts :: proc() {
	client_facts()
	script_drain()
}

// Runs one script command now, in order with anything queued before (main thread). finished:
// a long-running command's finished event already came (its result is in last_finished).
script_command :: proc(c: core.Command, caller: core.Caller) -> (id: u64, r: core.Result, finished: bool) {
	// a separate core: the script's commands go over the window's link, as the line's caller (the
	// core honours it in test mode); a long-running one's finished comes as the core's finished
	// message (client_core.odin)
	if client_separate() {
		rr: core.Result
		rr, id = client_call_wait(c, SCRIPT_CORE_WAIT, caller)
		if id != 0 && id == autotest.early_request { // it finished while its result was read
			log("finished", id, autotest.early_finished)
			delete(autotest.last_finished)
			autotest.last_finished, autotest.early_finished, autotest.early_request = autotest.early_finished, "", 0
			if rr.created_id == 0 do rr.created_id = autotest.early_created // $last, as in process (a tab host's answer)
			finished = true
		}
		return id, core.result_clone(rr, runtime.heap_allocator()), finished
	}
	reply: core.Reply
	id = core.inbox_submit(c, caller, &reply)
	autotest.submitted, autotest.submitted_done = id, false
	script_drain()
	finished = autotest.submitted_done
	autotest.submitted, autotest.submitted_done = 0, false
	return id, reply.result, finished
}

// A failed script line: counted (exit status 1 at quit), and logged with a marker the scene scripts
// look for ("ASSERT FAILED", or "TIMEOUT" for a wait): many run the app with `|| true` and read
// its log, so a failure without one ("dragtab: no such tab or place") would pass the scene.
@(private = "file")
// The window's replica must equal the core's State after every script step (design §10.2,
// M3-F, R14): a difference is a UI write that bypassed commands or a change the state stream
// missed, and fails the scene. The window then gets the whole state again.
autotest_check_replica :: proc() {
	autotest.replica_checked = time.tick_now()
	if d := client_check(); d != "" do script_fail(fmt.tprintf("the window's replica diverged from the core's State: %s", d))
}

// Each shown terminal's copy in the window must equal the core's terminal after every script step
// (design §10.2, M3-H): the screen hash of both (term_view_stream.odin).
autotest_check_terms :: proc() {
	cpu := cpu_seconds()
	defer autotest.terms_check_cpu += cpu_seconds() - cpu
	d, n := term_views_check()
	autotest.terms_checked += n
	if d != "" do script_fail(fmt.tprintf("the window's terminal copy diverged from the core's: %s", d))
}

script_fail :: proc(args: ..any) {
	autotest.failures += 1
	msg := fmt.tprint(..args)
	if strings.has_prefix(msg, "ASSERT FAILED") || strings.has_prefix(msg, "TIMEOUT") do log(msg)
	else do log("ASSERT FAILED", msg)
	at := &autotest
	if !at.fail_fast || !core.autotest_active do return
	// fail fast: stop here, as `quit` does (exit status 1: main.odin); no "done:" line, which the
	// scene scripts read as a script that ran to its end
	line := at.next > 0 && at.next <= len(at.lines) ? strings.trim_space(at.lines[at.next - 1]) : ""
	log(fmt.tprintf("ASSERT FAILED (stopped at line %d of %s; fail fast): %s (%d asserts, %d failed)",
		at.next, at.path, line, at.asserts, at.failures))
	if at.step_file != "" do script_write_step(at.next - 1, fmt.tprintf("%s   (failed; stopped)", line))
	at.next = len(at.lines)
	at.waiting_for = ""
	at.eventually_on = false
	core.app_quitting = true // the script ends the run: no confirmation
	script_show_again()
	app_request_quit()
	core.autotest_active = false
}

FRAMES_OFF_MAX :: 90 * time.Second

// frame(): whether `frames off` holds now. Only the core loop's timer runs the script meanwhile;
// without it nothing would, so after FRAMES_OFF_MAX the script fails instead of hanging.
script_frames_off :: proc() -> bool {
	at := &autotest
	if !at.frames_off do return false
	if time.tick_diff(at.frames_back, time.tick_now()) < 0 {
		// sokol's frame goes on after ours and would carry out a quit (it closes the window): drop
		// the request, as a frame that never runs would never see it (core_quit_stalled's case)
		sapp.cancel_quit()
		return true
	}
	at.frames_off = false
	script_fail(fmt.tprintf("TIMEOUT: frames off for %v and the script did not move on (nothing ticked the core: core_loop.odin's timer)", FRAMES_OFF_MAX))
	return false
}

// The run ends: frames again (sokol quits from a frame; app_request_quit shows a hidden app).
script_show_again :: proc() {
	autotest.frames_off = false
}

// The line starting now (DECKHAND_SCRIPT_STEP), so a hung or killed run says where it was.
@(private = "file")
script_write_step :: proc(idx: int, line: string) {
	text := fmt.tprintf("%s:%d: %s\n", autotest.path, idx + 1, line)
	_ = os.write_entire_file(autotest.step_file, transmute([]u8)text)
}

// A script line whose work is in the core's process, sent to a separate core (window_link.odin's
// script_core_line), its result waited for.
script_on_core :: proc(line: string) {
	client_facts()
	id := client_next_id()
	client_send_raw(core.window_msg_script_core(line, id))
	start := time.tick_now()
	for !(id in client.results) && !client.lost && time.tick_since(start) < SCRIPT_CORE_WAIT do client_io(20)
	if !(id in client.results) {
		script_fail("the background core did not answer:", line)
		return
	}
	if r := client_take_result(id); !r.ok do script_fail(line, "in the core:", r.error)
}

// A script's quit with a separate core: the core quits as an in-process Deckhand would (Quit,
// confirmed as the user would), so the next run on this data dir starts a fresh core.
script_core_quit :: proc() {
	r, _ := client_call_wait(core.Quit{}, SCRIPT_CORE_WAIT)
	if !r.ok && r.confirm_token != "" do r, _ = client_call_wait(core.Quit{confirm = r.confirm_token}, SCRIPT_CORE_WAIT)
	if !r.ok {
		fmt.eprintln("[autotest] the core did not quit:", r.error)
		return
	}
	// until it is gone (its instance lock with it), as an in-process quit is when the process ends
	start := time.tick_now()
	for !client.lost && time.tick_since(start) < SCRIPT_CORE_WAIT do client_io(20)
}

// The snapshot a script reads. A separate core: what the window sent before (a click's command,
// its facts: focus.step, an app tab's inspect…) has reached the core and its delta came back
// (client_barrier), as in process, where a click's command runs at once.
script_state_json :: proc() -> string {
	if client_separate() do client_barrier()
	return core.state_json()
}

// Called for every event (events.odin).
autotest_on_event :: proc(ev: core.Event) {
	// finished inside script_command's own drain (a fast app's reply): before the script knows
	// it has to wait, so kept here
	if f, ok := ev.(core.Finished_Event); ok && autotest.submitted != 0 && f.request_id == autotest.submitted {
		log("finished", f.request_id, core.result_json(f.result))
		delete(autotest.last_finished)
		autotest.last_finished = strings.clone(core.result_json(f.result))
		autotest.submitted_done = true
		return
	}
	if f, ok := ev.(core.Finished_Event); ok && autotest.bg_request != 0 && f.request_id == autotest.bg_request {
		log("finished", f.request_id, core.result_json(f.result))
		delete(autotest.last_finished)
		autotest.last_finished = strings.clone(core.result_json(f.result))
		autotest.bg_done = true
	}
	if f, ok := ev.(core.Finished_Event); ok && autotest.wait_request != 0 && f.request_id == autotest.wait_request {
		log("finished", f.request_id, core.result_json(f.result))
		delete(autotest.last_finished)
		autotest.last_finished = strings.clone(core.result_json(f.result))
		autotest.wait_request = 0
		// a separate core: what a tab host's call made comes with its finished ($last, as in process)
		if client_separate() && f.result.created_id != 0 do autotest.prev_created, autotest.last_created = autotest.last_created, f.result.created_id
		return
	}
	if f, ok := ev.(core.Finished_Event); ok && client_separate() && f.request_id != autotest.bg_request {
		delete(autotest.early_finished)
		autotest.early_request, autotest.early_finished, autotest.early_created = f.request_id, strings.clone(core.result_json(f.result)), f.result.created_id
	}
}

@(private = "file")
expand_vars :: proc(s: string) -> string {
	at := &autotest
	cs := core.cur()
	tab, pitab: u64
	pisession: string
	if cs != nil {
		tab = cs.active_tab
		pitab = cs.tabs[0].id
		pisession = cs.pi_session_id
	}
	cwd, _ := os.get_working_directory(context.temp_allocator)
	// longest names first: $pitab before $tab, $pisession before $session
	vars := [?][2]string {
		{"$last", fmt.tprint(at.last_created)},
		{"$prev", fmt.tprint(at.prev_created)},
		{"$token", at.last_token},
		{"$project", fmt.tprint(state.selected_project)},
		{"$pisession", pisession},
		{"$session", fmt.tprint(state.current_session)},
		{"$pitab", fmt.tprint(pitab)},
		{"$hometab", fmt.tprint(core.home_tab() != nil ? core.home_tab().id : 0)},
		{"$tab", fmt.tprint(tab)},
		{"$chats", fmt.tprint(core.chats_project() != nil ? core.chats_project().id : 0)},
		{"$homedir", os.get_env("HOME", context.temp_allocator)},
		{"$notesdir", state.settings.home_dir},
		{"$datadir", core.home_root},
		{"$cwd", cwd},
	}
	out := s
	for v in vars do out, _ = strings.replace_all(out, v[0], v[1], context.temp_allocator)
	// $pane0 … $pane7: the current session's panes by slot; $ptab0 …: the tab each shows (panes.odin)
	if cs != nil && strings.contains(out, "$p") do for p in cs.panes {
		out, _ = strings.replace_all(out, fmt.tprintf("$pane%d", p.slot), fmt.tprint(p.id), context.temp_allocator)
		out, _ = strings.replace_all(out, fmt.tprintf("$ptab%d", p.slot), fmt.tprint(p.active), context.temp_allocator)
	}
	return out
}

// The terminal of the tab pane SLOT of the current session shows (nil: none).
@(private = "file")
script_pane_term :: proc(slot: string) -> ^Term_View {
	cs := core.cur()
	if cs == nil do return nil
	n := int(num(slot))
	for &p in cs.panes do if p.slot == n do return pane_view(&p)
	return nil
}

// dragtab's press (the centre of tab TAB) and release points (framebuffer px), from the last
// layout's rects (the same tab_drop_input a drag reads).
@(private = "file")
script_tab_drag_points :: proc(args: []string) -> (x1, y1, x2, y2: f32, ok: bool) {
	cs := core.cur()
	if cs == nil || len(args) < 2 do return
	i := int(num(args[0]))
	if i < 0 || i >= len(cs.tabs) do return
	d := clay.GetElementData(clay.ID("tab", u32(i)))
	if !d.found do return
	b := d.boundingBox
	x1, y1 = b.x + b.width / 2, b.y + b.height / 2
	if args[1] == "outside" do return x1, y1, sapp.widthf() + 40 * app.dpi, y1 + 100 * app.dpi, true
	if args[1] == "by" {
		if len(args) < 4 do return
		return x1, y1, x1 + num(args[2]) * app.dpi, y1 + num(args[3]) * app.dpi, true
	}
	if len(args) < 3 do return
	input := tab_drop_input(cs, cs.tabs[i].id)
	slot := int(num(args[2]))
	p: Drop_Pane
	found := false
	for &x in cs.panes do if x.slot == slot do for dp in input.panes do if dp.id == x.id {
		p = dp
		found = true
	}
	if !found do return
	z := p.zone
	in_edge := px(TAB_DROP_EDGE_MIN) / 2
	switch args[1] {
	case "strip":
		if len(args) < 4 || p.strip.z <= 0 do return
		gap := int(num(args[3]))
		y2 = p.strip.y + p.strip.w / 2
		if gap < len(p.tabs) do x2 = p.tabs[gap].rect.x + px(2)
		else if n := len(p.tabs); n > 0 do x2 = p.tabs[n - 1].rect.x + p.tabs[n - 1].rect.z + px(4)
		else do x2 = p.strip.x + px(4)
	case "centre": x2, y2 = z.x + z.z / 2, z.y + z.w / 2
	case "left":   x2, y2 = z.x + in_edge, z.y + z.w / 2
	case "right":  x2, y2 = z.x + z.z - in_edge, z.y + z.w / 2
	case "up":     x2, y2 = z.x + z.z / 2, z.y + in_edge
	case "down":   x2, y2 = z.x + z.z / 2, z.y + z.w - in_edge
	case: return
	}
	return x1, y1, x2, y2, z.z > 0
}

// divider pane SLOT D [clicks N]: drags (or clicks) the divider of the nearest split that has pane
// SLOT before it (in its first child), D logical px across the divider's line.
@(private = "file")
script_pane_divider :: proc(args: []string) -> bool {
	cs := core.cur()
	if cs == nil || len(args) < 2 do return false
	n := int(num(args[0]))
	pane: u64
	for p in cs.panes do if p.slot == n do pane = p.id
	leaf := -1
	for x, i in cs.nodes do if x.leaf && x.pane == pane do leaf = i
	if leaf < 0 do return false
	split := u64(0)
	across := true
	for at := leaf; cs.nodes[at].parent >= 0; at = cs.nodes[at].parent {
		par := cs.nodes[cs.nodes[at].parent]
		if par.a == at {
			split, across = par.id, par.dir == .Right
			break
		}
	}
	if split == 0 do return false
	d := clay.GetElementData(clay.ID("pane_div", u32(split)))
	if !d.found do return false
	b := d.boundingBox
	x, y := b.x + b.width / 2, b.y + b.height / 2
	if args[1] == "clicks" {
		for _ in 0 ..< (len(args) > 2 ? int(num(args[2])) : 2) {
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
		}
		return true
	}
	dd := num(args[1]) * app.dpi
	dx, dy := across ? dd : 0, across ? 0 : dd
	send({type = .MOUSE_MOVE, mouse_x = x, mouse_y = y})
	send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
	for i in 1 ..= 8 do send({type = .MOUSE_MOVE, mouse_x = x + dx * f32(i) / 8, mouse_y = y + dy * f32(i) / 8, modifiers = sapp.MODIFIER_LMB})
	send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x + dx, mouse_y = y + dy})
	return true
}

total_bytes_in :: proc() -> int {
	n := 0
	for _, t in core.terms do n += t.bytes_in
	return n
}

// The open context menu's rows: labels joined by "|", "-" for a divider (temp).
@(private = "file")
menu_rows_text :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	n := 0
	for it in menu_items() {
		if it.note do continue
		if n > 0 do strings.write_byte(&b, '|')
		strings.write_string(&b, it.sep ? "-" : it.label)
		n += 1
	}
	return strings.to_string(b)
}

// The script's checks that only read (no input, no side effect a second look would repeat):
// what `eventually` may run again every frame, and what the wait audit runs early.
script_is_check :: proc(cmd: string) -> bool {
	switch cmd {
	case "assert_file", "assert_not_file", "assert_tip", "assert_drawn", "assert_not_drawn", "assert_md", "assert_not_md",
	     "assert_opened", "assert_menurows", "assert_revealed", "assert_toast", "assert_clipboard", "assert_notice",
	     "assert_files", "assert_not_files", "assert_rows", "assert_link", "assert_drawn_selection", "assert_screen",
	     "assert_not_screen", "assert_palette", "assert_selection", "assert_pane_selection", "assert_pane_cols", "hittest", "assert_in_window", "assert_window",
	     "assert_menu", "assert_state", "assert_result", "assert_finished":
		return true
	}
	return false
}

// Runs check cmd (script_is_check) now: ok, and what the log says either way (temp-allocated).
script_check :: proc(cmd, rest: string, args: []string) -> (ok: bool, msg: string) {
	at := &autotest
	switch cmd {
	case "assert_file", "assert_not_file": // assert_file PATH TEXT: the file contains TEXT
		path, _, text := strings.partition(strings.trim_space(expand_vars(rest)), " ")
		data, _ := os.read_entire_file(path, context.temp_allocator)
		ok = strings.contains(string(data), text) == (cmd == "assert_file")
		msg = ok ? fmt.tprint("assert ok:", cmd, path) : fmt.tprintf("ASSERT FAILED %s %s %q", cmd, path, text)
	case "assert_tip":
		got := ""
		if tip_due() do app.redraw = true // as this frame would after the step (frames may be throttled)
		if tip.shown && !tip.off {
			label, keys := hit_tip(ui_hover)
			got = keys != "" ? fmt.tprintf("%s %s", label, keys) : label
		}
		ok = got == rest
		msg = ok ? fmt.tprint("assert ok: tooltip", fmt.tprintf("%q", got)) : fmt.tprintf("ASSERT FAILED tooltip: got %q, want %q (hover %v, shown %v, off %v)", got, rest, ui_hover, tip.shown, tip.off)
	case "assert_drawn", "assert_not_drawn":
		// TEXT is (not) in any text drawn now
		cmds := ui_layout(sapp.widthf(), sapp.heightf())
		found := false
		for i in 0 ..< cmds.length {
			c := &cmds.internalArray[i]
			if c.commandType != .Text do continue
			t := c.renderData.text
			if strings.contains(string(t.stringContents.chars[:t.stringContents.length]), rest) do found = true
		}
		app.redraw = true
		ok = found == (cmd == "assert_drawn")
		if cmd == "assert_drawn" do msg = ok ? fmt.tprint("assert ok: drawn", fmt.tprintf("%q", rest)) : fmt.tprintf("ASSERT FAILED drawn: %q is not on screen", rest)
		else do msg = ok ? fmt.tprint("assert ok: not drawn", fmt.tprintf("%q", rest)) : fmt.tprintf("ASSERT FAILED drawn: %q is on screen", rest)
	case "assert_md", "assert_not_md":
		got := md_shown_text()
		ok = strings.contains(got, rest) == (cmd == "assert_md")
		msg = ok ? fmt.tprint("assert ok:", cmd, fmt.tprintf("%q", rest)) : fmt.tprintf("ASSERT FAILED %s %q (preview: %q)", cmd, rest, got[:min(len(got), 400)])
	case "assert_opened":
		ok = autotest.opened_url == rest
		msg = ok ? fmt.tprint("assert ok: opened", rest) : fmt.tprintf("ASSERT FAILED opened %q, want %q", autotest.opened_url, rest)
	case "assert_menurows":
		// the open context menu's rows: labels joined by "|", "-" for a divider, notes left out
		got := menu.open ? menu_rows_text() : "<no menu>"
		ok = got == rest
		msg = ok ? fmt.tprint("assert ok: menu rows", got) : fmt.tprintf("ASSERT FAILED menu rows: %q, want %q", got, rest)
	case "assert_revealed":
		// the last path shown in Finder (platform.reveal, or a Reveal_In_Finder) contains TEXT; "-" = none since revealed_clear
		got := autotest.revealed != "" ? autotest.revealed : core.fs_model.revealed
		ok = rest == "-" ? got == "" : got != "" && strings.contains(got, rest)
		msg = ok ? fmt.tprint("assert ok: revealed", got) : fmt.tprintf("ASSERT FAILED revealed: %q, want %q in it", got, rest)
	case "assert_toast":
		// the toast showing now contains TEXT; "-" = none shows
		ok = rest == "-" ? toast.text == "" : toast.text != "" && strings.contains(toast.text, rest)
		msg = ok ? fmt.tprint("assert ok: toast", fmt.tprintf("%q", toast.text)) : fmt.tprintf("ASSERT FAILED toast: %q, want %q", toast.text, rest)
	case "assert_clipboard":
		// what Deckhand last put on the clipboard contains TEXT ("\n" = a line break); "-" = nothing since clipboard_clear
		want, _ := strings.replace_all(rest, `\n`, "\n", context.temp_allocator)
		ok = rest == "-" ? autotest.clipboard == "" : autotest.clipboard != "" && strings.contains(autotest.clipboard, want)
		msg = ok ? fmt.tprint("assert ok: clipboard", fmt.tprintf("%q", autotest.clipboard)) : fmt.tprintf("ASSERT FAILED clipboard: %q, want %q", autotest.clipboard, want)
	case "assert_notice":
		e := tab_editor()
		got := e != nil ? e.notice : "<no editor>"
		ok = strings.contains(got, rest)
		msg = ok ? fmt.tprint("assert ok: notice", fmt.tprintf("%q", got)) : fmt.tprintf("ASSERT FAILED notice: %q, want %q", got, rest)
	case "assert_files", "assert_not_files":
		// the shown tree's rows (Files or Settings; files_rows_text) contain TEXT ("\n" = a line break)
		want, _ := strings.replace_all(rest, `\n`, "\n", context.temp_allocator)
		got := core.files_rows_text(core.tree_rows())
		has := strings.contains(got, want)
		ok = has == (cmd == "assert_files")
		if cmd == "assert_files" do msg = ok ? fmt.tprint("assert ok: files rows contain", fmt.tprintf("%q", want)) : fmt.tprintf("ASSERT FAILED files rows: %q not in %q", want, got)
		else do msg = ok ? fmt.tprint("assert ok: files rows lack", fmt.tprintf("%q", want)) : fmt.tprintf("ASSERT FAILED files rows: %q in %q", want, got)
	case "assert_rows":
		section, _, want := strings.partition(rest, " ")
		got := script_rows_text(section)
		ok = got == want
		msg = ok ? fmt.tprint("assert ok: rows", section, "=", got) : fmt.tprintf("ASSERT FAILED rows %s: got %q, want %q", section, got, want)
	case "assert_link":
		// assert_link URL|-: the link underlined under the pointer (⌘ held), or none
		t := active_view()
		got := t != nil && t.link_on ? t.link.url : "-"
		ok = got == rest
		msg = ok ? fmt.tprint("assert ok: link", got) : fmt.tprintf("ASSERT FAILED link %q, want %q", got, rest)
	case "assert_drawn_selection":
		// assert_drawn_selection N: selected cells in the last frame drawn (N > 0: "some"; 0: none)
		t := active_view()
		got := t != nil ? t.drawn_selected : -1
		want := len(args) > 0 ? int(num(args[0])) : 0
		ok = (want == 0 && got == 0) || (want > 0 && got > 0)
		msg = ok ? fmt.tprint("assert ok: drawn selected cells =", got) : fmt.tprintf("ASSERT FAILED drawn selection: got %d cells, want %s", got, want > 0 ? "some" : "none")
	case "assert_screen":
		ok = strings.contains(screen_text(), rest)
		msg = ok ? fmt.tprint("assert ok: on screen:", rest) : fmt.tprintf("ASSERT FAILED screen: %q not found", rest)
	case "assert_not_screen":
		ok = !strings.contains(screen_text(), rest)
		msg = ok ? fmt.tprint("assert ok: not on screen:", rest) : fmt.tprintf("ASSERT FAILED screen: %q found", rest)
	case "assert_palette":
		rs := palette_results()
		i := int(num(args[0]))
		got := i < len(rs) ? rs[i].key : "<none>"
		ok = got == args[1]
		msg = ok ? fmt.tprint("assert ok: palette", i, "=", got) : fmt.tprintf("ASSERT FAILED palette %d: got %s, want %s", i, got, args[1])
	case "assert_pane_cols":
		t := script_pane_term(args[0])
		cs := core.cur()
		w: f32
		if cs != nil do for p in cs.panes do if p.slot == int(num(args[0])) do w = p.rect.z
		want := u16(max(2, int((w - 2 * term_pad()) / font.cell_w)))
		ok = t != nil && t.cols == want && t.w == w
		msg = ok ? fmt.tprint("assert ok: pane", args[0], "cols =", want) : fmt.tprintf("ASSERT FAILED pane %s cols: got %d (%.0f px), want %d (%.0f px)", args[0], t != nil ? t.cols : 0, t != nil ? t.w : 0, want, w)
	case "assert_pane_selection":
		slot, _, want := strings.partition(strings.trim_space(expand_vars(rest)), " ")
		t := script_pane_term(slot)
		got := t != nil ? term_view_selection(t.tab_id) : "<no terminal>"
		ok = got == want
		msg = ok ? fmt.tprint("assert ok: pane", slot, "selection =", fmt.tprintf("%q", got)) : fmt.tprintf("ASSERT FAILED pane %s selection: got %q, want %q", slot, got, want)
	case "assert_selection":
		got := ""
		if f, _, _ := focused_field(); f != nil do got = tf_selected_text(f)
		else if t := active_view(); t != nil do got = term_view_selection(t.tab_id)
		ok = got == rest
		msg = ok ? fmt.tprint("assert ok: selection =", fmt.tprintf("%q", got)) : fmt.tprintf("ASSERT FAILED selection: got %q, want %q", got, rest)
	case "hittest":
		got := test_hit(num(args[0]) * app.dpi, num(args[1]) * app.dpi)
		name := got == 1 ? "view" : (got == 0 ? "titlebar" : "nothing")
		ok = name == args[2]
		msg = ok ? fmt.tprint("assert ok: hit", args[0], args[1], "=", name) : fmt.tprintf("ASSERT FAILED hit %s %s: got %s, want %s", args[0], args[1], name, args[2])
	case "assert_in_window":
		// assert_in_window ID: the element is laid out, wholly inside the window
		_ = ui_layout(sapp.widthf(), sapp.heightf())
		d := clay.GetElementData(clay.ID(args[0]))
		b := d.boundingBox
		ok = d.found && b.x >= -0.5 && b.y >= -0.5 && b.x + b.width <= sapp.widthf() + 0.5 && b.y + b.height <= sapp.heightf() + 0.5
		msg = ok ? fmt.tprint("assert ok: in window", args[0]) : fmt.tprintf("ASSERT FAILED in window: %s at %v (found %v), window %vx%v", args[0], b, d.found, sapp.widthf(), sapp.heightf())
	case "assert_window":
		// the window's own appearance (title bar, traffic lights, folder picker)
		got := test_window_light() ? "light" : "dark"
		ok = got == args[0]
		msg = ok ? fmt.tprint("assert ok: window appearance", got) : fmt.tprintf("ASSERT FAILED window appearance: got %s, want %s", got, args[0])
	case "assert_menu":
		it := menubar_find(args[0])
		on, checked := menubar_state(menubar_tag(it)) // -1 when there is no such item: false, false
		got := args[1] == "enabled" || args[1] == "disabled" ? (on ? "enabled" : "disabled") : (checked ? "checked" : "unchecked")
		ok = it != nil && got == args[1]
		msg = ok ? fmt.tprint("assert ok: menu", args[0], got) : fmt.tprintf("ASSERT FAILED menu %s: got %s, want %s", args[0], it != nil ? got : "no such item", args[1])
	case "assert_state", "assert_result", "assert_finished":
		path, _, want := strings.partition(strings.trim_space(rest), " ")
		src := cmd == "assert_state" ? script_state_json() : cmd == "assert_finished" ? at.last_finished : at.last_result
		got := core.json_path(src, path)
		want = expand_vars(want)
		ok = got == want
		msg = ok ? fmt.tprint("assert ok:", path, "=", got) : fmt.tprintf("ASSERT FAILED %s: got %q, want %q", path, got, want)
	}
	return
}

// assert_rows' text for a section of the left column (temp).
@(private = "file")
script_rows_text :: proc(section: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	switch section {
	case "open":
		for s, i in core.sidebar_open() {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, core.open_session_title(s))
		}
	case "projects":
		for r, i in core.sidebar_projects() {
			if i > 0 do strings.write_byte(&b, ',')
			if r.project == nil do fmt.sbprintf(&b, "%s%s/", strings.repeat("+", r.depth, context.temp_allocator), r.name)
			else do fmt.sbprintf(&b, "%s%s", strings.repeat("+", r.depth, context.temp_allocator), core.project_name(r.project^))
		}
	case "sessions", "chats":
		for r, i in core.sidebar_sessions(section == "chats" ? .Chats : .Sessions) {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, core.session_label(r.session^, section == "chats"))
		}
	case "machines":
		// each other machine: name:status:the tabs of its open sessions here (machine_mirror.odin)
		for m, i in state.machines {
			if i > 0 do strings.write_byte(&b, ',')
			n := 0
			for s in state.open_sessions do if s.machine == m.no do n += len(s.tabs)
			fmt.sbprintf(&b, "%s:%s:%d", m.name, core.MACHINE_STATUS_NAMES[m.status], n)
		}
	case "tree":
		// as drawn in the last layout: projects, the expanded one's sessions as >title
		for id, i in drawn.proj {
			if i > 0 do strings.write_byte(&b, ',')
			if p := core.find_project(id); p != nil do strings.write_string(&b, core.project_name(p^))
			if id != state.selected_project do continue
			for sid in drawn.sess {
				for l in core.sessions_with_new(.Sessions, state.sessions[:]) do if l.id == sid do fmt.sbprintf(&b, ",>%s", core.session_label(l))
			}
		}
	}
	got := strings.to_string(b)
	return got == "" ? "-" : got
}

// An element-addressed line whose element (menu row, preview text) is not laid out yet: true =
// try the line again next frame, for up to ELEMENT_WAIT; false = time is up, fail as before.
ELEMENT_WAIT :: 5 * time.Second

@(private = "file")
script_retry :: proc(idx: int) -> bool {
	at := &autotest
	now := time.tick_now()
	if at.elem_until == {} do at.elem_until = time.tick_add(now, ELEMENT_WAIT)
	if time.tick_diff(at.elem_until, now) >= 0 {
		at.elem_until = {}
		return false
	}
	app.redraw = true
	at.retry_line, at.next = idx, idx
	return true
}

// A shot is taken once the raised window has drawn this many frames and this long has passed
// (it was a fixed second): the frame on screen is then one drawn after the raise.
SHOT_FRAMES :: 3
SHOT_MIN :: 150 * time.Millisecond

// Lines that click, hover or drag an element where the last layout put it: they wait for a
// frame drawn after the last input, so the layout they read shows what that input did.
@(private = "file")
script_reads_layout :: proc(cmd: string) -> bool {
	switch cmd {
	case "clickid", "rclickid", "hover", "sweep", "dragid", "dragtab", "clickmenu", "clickmd", "clicktext", "divider", "drop":
		return true
	}
	return false
}

// Lines that put input in (or change what is laid out) as the user would.
@(private = "file")
script_is_input :: proc(cmd: string) -> bool {
	switch cmd {
	case "type", "key", "paste", "scroll", "click", "drag", "clicks", "clickcell", "mousecell", "clicktext", "clickid",
	     "rclickid", "dragid", "dragtab", "hover", "sweep", "clickmenu", "clickmd", "divider", "drop", "menu", "menu_key", "ime_press",
	     "ime_mark", "ime_commit", "ime_key", "command", "ui_command", "control_command", "pi_command", "pi_command_bg",
	     "resize", "window", "system_appearance", "toast_clear", "jobs_ui", "jobs_clock", "window_active", "copy":
		return true
	}
	return false
}

// DECKHAND_WAIT_AUDIT=1 (tests/wait_audit.py): for every `wait` followed by checks, whether each
// check already held before the line ahead of the wait ran (A) and when the wait began (B); the
// check's own run is C. A check that held at A did not need the wait to become true: it may be a
// check that something stays as it was, so its wait is kept. Logged, never counted or failed.
@(private = "file")
script_audit :: proc(idx: int, cmd: string) {
	at := &autotest
	at.audit_wait = -1
	if cmd == "wait" {
		script_audit_block(idx, "B")
		at.audit_wait, at.audit_k = idx, 0
		return
	}
	// the next line that is not a comment: a wait?
	for j in idx + 1 ..< len(at.lines) {
		l := strings.trim_space(at.lines[j])
		if l == "" || l[0] == '#' do continue
		if strings.has_prefix(l, "wait ") do script_audit_block(j, "A")
		break
	}
}

@(private = "file")
script_audit_block :: proc(wait_idx: int, phase: string) {
	at := &autotest
	k := 0
	for j in wait_idx + 1 ..< len(at.lines) {
		l := strings.trim_space(at.lines[j])
		if l == "" || l[0] == '#' do continue
		cmd, _, rest := strings.partition(l, " ")
		if !script_is_check(cmd) do break
		ok, _ := script_check(cmd, rest, strings.fields(rest, context.temp_allocator))
		log(fmt.tprintf("AUDIT %s %d %d %s", phase, wait_idx + 1, k, ok ? "pass" : "fail"))
		k += 1
	}
}

// Commands waitresult may run again: they only read.
@(private = "file")
script_read_only :: proc(type: string) -> bool {
	switch type {
	case "changes_list", "editor_state", "list_worktrees", "app_events", "session_info", "get_state", "job_list":
		return true
	}
	return false
}
