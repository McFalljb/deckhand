package main

// Scripted input for testing without touching other apps: when
// PI_DESK_SCRIPT=<file> is set, each line is played in order from the frame
// loop, and synthetic sokol events go through the normal event() handler.
// OS-level input (Cocoa -> sokol) is therefore NOT covered by these runs.
//
//   wait MS                    sleep (frames keep running)
//   waitfor TEXT [MS]          until TEXT is on screen (default 30 s)
//   type TEXT                  KEY_DOWN/CHAR/KEY_UP per character
//   key NAME [shift|ctrl|alt|cmd ...]   enter tab backspace escape up down left right
//                              pageup pagedown home end space comma slash lcmd (⌘ alone), or a letter/digit
//   paste TEXT                 clipboard + Cmd+V ("\n" -> newline)
//   scroll DY X Y              wheel at logical X,Y
//   click X Y                  left click at logical X,Y
//   drag X1 Y1 X2 Y2 [shift]   left drag
//   clicks N X Y               N quick left clicks at logical X,Y (2 = double-click)
//   clickcell N COL ROW [COL2 ROW2]  N quick clicks on a terminal cell (then drag to COL2,ROW2)
//   mousecell down|move|up COL ROW [shift|cmd|ctrl ...]   one step of a press held across frames
//                              (a drag the frame loop draws in between); COL/ROW may be off the grid;
//                              hover (a move, no button), click, rclick (right button) too
//   assert_link URL|-          the terminal link underlined under the pointer (⌘ held), or none
//   assert_drawn_selection N   the last drawn frame showed selected terminal cells (N > 0) or none (0)
//   clicktext N NAME OFFSET    N quick clicks in a text element at byte OFFSET of its text
//   beeps [WANT]               AppKit beeps for unhandled keys so far (counted, not sounded;
//                              the first use starts counting); with WANT, assert the count
//   assert_screen TEXT         TEXT is on the active terminal's screen now
//   assert_palette INDEX KEY   the palette's result INDEX has KEY (action:new_chat, tab:3, ...)
//   assert_selection TEXT      the focused field's selection, else the terminal's, equals TEXT
//                              (read directly: the system clipboard is not touched)
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
//   rclickid NAME [INDEX]      right click there (context menus)
//   assert_files TEXT          the Files tree's rows (indented names, "/" after open folders)
//                              contain TEXT ("\n" = a line break); assert_not_files: do not
//   dragid FROM INDEX TO       left drag from element FROM INDEX to element TO (centres)
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
//                              `clicks 2` double-clicks it instead
//   hover NAME [INDEX]         move the pointer to the centre of a Clay element
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
//   assert_clipboard TEXT|-    what pi-desk last put on the clipboard contains TEXT; - = nothing
//   clipboard_clear            forget it (the system clipboard is left as it is)
//   assert_md TEXT             the shown Markdown preview's text (labels and markers too)
//                              contains TEXT; assert_not_md: does not
//   clickmd TEXT               left click the middle of the preview's first text piece
//                              containing TEXT (scrolled into view first)
//   assert_opened URL          the last link opened in the default browser or mail app (test
//                              mode only logs it; Markdown and terminal links)
//   state                      log modes the app enabled (mouse, paste, kitty keys)
//   resize W H                 window content size (logical px)
//   shot NAME                  screenshot of this window to build/shots/NAME.png (raised without focus)
//   dump NAME                  visible terminal text to build/NAME.txt
//   cpu_begin / cpu_end LABEL  own process CPU% (getrusage) + frames drawn
//   atlas                      glyph atlas size, cached glyphs, rasterised, evictions
//   window back|front          the window goes to the background / comes to the front
//                              (UNFOCUSED/FOCUSED through event(); the app's own idea only)
//   deactivate                 hand focus back to the previously active app
//   minimize / restore         miniaturize / deminiaturize the window
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
//                              (waits for "finished" if the result is pending)
//   ui_command JSON            the same as the user (caller ui), e.g. to change
//                              confirmation settings, which scripts may not
//   thread_command JSON        submit from a worker thread, as a socket would
//                              (no reply; check with assert_state; logs wakes)
//   assert_state PATH VALUE    state JSON at PATH (a.b.0.c; "#" = length) equals VALUE
//   waitstate MS PATH VALUE    until the state JSON has VALUE at PATH (fails after MS)
//   jobs_clock SECONDS         the jobs' scheduler clock moves on (jobs.odin), then a due check
//   window_active on|off       as if pi-desk were in front (no OS notifications) or behind
//   jobs_ui ID|- [limits]      open a Jobs row (and the limits) on the Jobs tab
//   replace_in_file PATH OLD|NEW   edit a file as another program would
//   assert_file PATH TEXT      the file contains TEXT; assert_not_file: does not
//   result_file NAME           the last command's result JSON to build/NAME.json
//   assert_result PATH VALUE   same, on the last command's result JSON
//   assert_finished PATH VALUE same, on the last long-running command's finished result
//   state_json NAME            app state as JSON to build/NAME.json
//   quit                       quit without confirmation; exit status 1 if an assert failed
//
// Variables in command/assert lines: $last (last created_id), $token (last
// confirmation token), $project (selected project), $session (current open
// session), $tab (its active tab), $pitab (its pi tab), $pisession (its pi
// session id), $hometab (Home's pi tab), $chats (the Chats entry's project
// id), $homedir ($HOME), $notesdir (the main folder, home_dir), $datadir (the data dir), $cwd (pi-desk's working directory). assert_screen, waitfor and dump read
// the terminal with the keyboard (Home's while its pane shows).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:thread"
import "core:time"
import gh "ghostty"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"

Autotest :: struct {
	lines:        []string,
	next:         int,
	wait_until:   time.Tick,
	waiting_for:  string,
	wait_state:   [2]string, // waitstate: path, value (owned; "" = none)
	wait_exit:    bool,
	pending_shot: string,
	deadline:     time.Tick,
	cpu_wall:     time.Tick,
	cpu_start:    f64,
	cpu_frames:   u64,
	cpu_bytes:    int,
	cpu_calls:    u64,
	active:       bool,
	wait_request: u64, // pending command: wait for its finished event
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
	clipboard:    string, // what pi-desk last put on the clipboard (platform.set_clipboard)
	revealed:     string, // the last path platform.reveal was asked to show
}

// Real keyboard/mouse input is dropped in test mode; script-driven native
// input (ime_*) is let through.
autotest_allows_input :: proc() -> bool {return !autotest.active || autotest.injecting}

autotest: Autotest

autotest_init :: proc() {
	path := os.get_env("PI_DESK_SCRIPT", context.temp_allocator)
	if path == "" do return
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fmt.eprintln("autotest: cannot read", path)
		return
	}
	autotest.lines = strings.split_lines(string(data))
	autotest.active = true
	// never a modal panel or a Finder window from a script
	platform.pick_folder = proc() -> string {
		p := autotest.fake_folder
		autotest.fake_folder = ""
		log("folder picker ->", p)
		return p
	}
	platform.reveal = proc(path: string) {
		log("reveal", path)
		delete(autotest.revealed)
		autotest.revealed = strings.clone(path)
	}
	// still the system clipboard (copy, then paste, in scenes); also kept for assert_clipboard
	platform.set_clipboard = proc(text: string) {
		delete(autotest.clipboard)
		autotest.clipboard = strings.clone(text)
		sapp.set_clipboard_string(strings.clone_to_cstring(text, context.temp_allocator))
	}
	platform.open_url = proc(url: string) -> bool {
		log("open url", url)
		delete(autotest.opened_url)
		autotest.opened_url = strings.clone(url)
		return true
	}
	platform.left_button = proc() -> bool {return autotest.left_down}
}

@(private = "file")
log :: proc(args: ..any) {
	fmt.print("[autotest ", time.now(), "] ", sep = "")
	fmt.println(..args)
}

// The terminal with the keyboard: Home's while its pane shows.
screen_text :: proc() -> string {
	t := key_term()
	if t == nil do return ""
	gh.render_state_update(t.rs, t.gt)
	b := strings.builder_make(context.temp_allocator)
	gh.render_state_get(t.rs, .Row_Iterator, &t.it)
	for gh.render_state_row_iterator_next(t.it) {
		gh.render_state_row_get(t.it, .Cells, &t.cells)
		for gh.render_state_row_cells_next(t.cells) {
			raw: gh.Cell
			gh.render_state_row_cells_get(t.cells, .Raw, &raw)
			wide: gh.Cell_Wide
			gh.cell_get(raw, .Wide, &wide)
			if wide == .Spacer_Tail do continue
			n: u32
			gh.render_state_row_cells_get(t.cells, .Graphemes_Len, &n)
			if n == 0 || n > 16 {
				strings.write_byte(&b, ' ')
				continue
			}
			buf: [16]u32
			gh.render_state_row_cells_get(t.cells, .Graphemes_Buf, &buf[0])
			for i in 0 ..< n do strings.write_rune(&b, rune(buf[i]))
		}
		strings.write_byte(&b, '\n')
	}
	t.changed = true // render state was consumed here; redraw
	return strings.to_string(b)
}

@(private = "file")
send :: proc(e: sapp.Event) {
	ev := e
	if e.mouse_button == .LEFT && e.type == .MOUSE_DOWN do autotest.left_down = true
	if e.mouse_button == .LEFT && e.type == .MOUSE_UP do autotest.left_down = false
	event(&ev)
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
autotest_step :: proc() {
	at := &autotest
	if !at.active do return
	if !at.started {
		// sokol activates the app at launch: hand focus straight back so the
		// user's keystrokes stay in their app (real input is dropped anyway)
		at.started = true
		app_deactivate()
	}
	now := time.tick_now()
	if at.pending_shot != "" do app.redraw = true // keep presenting while raised
	if time.tick_diff(at.wait_until, now) < 0 do return
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
		t := active_term()
		if t != nil && t.running && time.tick_diff(at.deadline, now) < 0 do return
		log("child exited:", t == nil || !t.running)
		at.wait_exit = false
	}
	if at.wait_request != 0 do return // autotest_on_event clears it
	if at.wait_state[0] != "" {
		got := json_path(state_json(), at.wait_state[0])
		if got == at.wait_state[1] {
			log("state reached:", at.wait_state[0], "=", got)
		} else if time.tick_diff(at.deadline, now) > 0 {
			script_fail(fmt.tprintf("TIMEOUT waiting for %s = %q (got %q)", at.wait_state[0], at.wait_state[1], got))
		} else {
			return
		}
		delete(at.wait_state[0])
		delete(at.wait_state[1])
		at.wait_state = {}
	}
	if at.waiting_for != "" {
		if strings.contains(screen_text(), at.waiting_for) {
			log("found", at.waiting_for)
			at.waiting_for = ""
		} else if time.tick_diff(at.deadline, now) > 0 {
			log("TIMEOUT waiting for", at.waiting_for)
			at.waiting_for = ""
		} else {
			return
		}
	}
	if !browser_wait_done(proc(msg: string) {script_fail(msg)}) do return // a web_* wait (browser.odin)
	if !app_wait_done(proc(msg: string) {script_fail(msg)}) do return // an app_* wait (app_tab.odin)
	for at.next < len(at.lines) {
		line := strings.trim_space(at.lines[at.next])
		at.next += 1
		if line == "" || line[0] == '#' do continue
		cmd, _, rest := strings.partition(line, " ")
		args := strings.fields(rest, context.temp_allocator)
		log(line)
		switch cmd {
		case "wait":
			at.wait_until = time.tick_add(now, time.Duration(num(rest)) * time.Millisecond)
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
			at.deadline = time.tick_add(now, time.Duration(ms) * time.Millisecond)
			return
		case "waitstate": // waitstate MS PATH VALUE…: until the state JSON has VALUE at PATH
			ms_s, _, pv := strings.partition(rest, " ")
			path, _, want := strings.partition(strings.trim_space(pv), " ")
			at.wait_state = {strings.clone(path), strings.clone(expand_vars(want))}
			at.deadline = time.tick_add(now, time.Duration(num(ms_s)) * time.Millisecond)
			return
		case "jobs_clock": // jobs_clock SECONDS: the jobs' clock moves on, then a due check
			jobs_clock_advance(i64(num(rest)))
		case "window_active": // window_active on|off: as if pi-desk were in front or behind
			app.window_active = strings.trim_space(rest) == "on"
		case "jobs_ui": // jobs_ui OPEN_ID [limits]: open a row (and the limits) on the Jobs tab
			jobs_ui_set(len(args) > 0 && args[0] != "-" ? args[0] : "", len(args) > 1 && args[1] == "limits")
		case "replace_in_file": // replace_in_file PATH OLD|NEW: an outside edit (another editor, an agent)
			path, _, pair := strings.partition(strings.trim_space(expand_vars(rest)), " ")
			old, _, new := strings.partition(pair, "|")
			data, _ := os.read_entire_file(path, context.temp_allocator)
			out, n := strings.replace(string(data), old, new, 1, context.temp_allocator)
			if !n do script_fail("replace_in_file: not found:", old)
			else do _ = os.write_entire_file(path, transmute([]u8)out)
		case "assert_file", "assert_not_file": // assert_file PATH TEXT: the file contains TEXT
			path, _, text := strings.partition(strings.trim_space(expand_vars(rest)), " ")
			data, _ := os.read_entire_file(path, context.temp_allocator)
			has := strings.contains(string(data), text)
			at.asserts += 1
			if has == (cmd == "assert_file") do log("assert ok:", cmd, path)
			else do script_fail(fmt.tprintf("ASSERT FAILED %s %s %q", cmd, path, text))
		case "waitexit":
			ms: f32 = 60000
			if len(args) > 0 do ms = num(args[0])
			at.wait_exit = true
			at.deadline = time.tick_add(now, time.Duration(ms) * time.Millisecond)
			return
		case "hover":
			args := strings.fields(expand_vars(rest), context.temp_allocator)
			idx: u32 = 0
			if len(args) > 1 do idx = u32(num(args[1]))
			d := clay.GetElementData(clay.ID(args[0], idx))
			if !d.found {
				log("no element", rest)
				continue
			}
			b := d.boundingBox
			send({type = .MOUSE_MOVE, mouse_x = b.x + b.width / 2, mouse_y = b.y + b.height / 2})
		case "clickid":
			args := strings.fields(expand_vars(rest), context.temp_allocator)
			idx: u32 = 0
			if len(args) > 1 do idx = u32(num(args[1]))
			d := clay.GetElementData(clay.ID(args[0], idx))
			if !d.found {
				log("no element", rest)
				continue
			}
			b := d.boundingBox
			x, y := b.x + b.width / 2, b.y + b.height / 2
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
		case "rclickid":
			idx: u32 = 0
			if len(args) > 1 do idx = u32(num(args[1]))
			d := clay.GetElementData(clay.ID(args[0], idx))
			if !d.found {
				script_fail("no element", rest)
				continue
			}
			b := d.boundingBox
			x, y := b.x + b.width / 2, b.y + b.height / 2
			send({type = .MOUSE_DOWN, mouse_button = .RIGHT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .RIGHT, mouse_x = x, mouse_y = y})
		case "assert_tip":
			got := ""
			if tip_due() do app.redraw = true // as this frame would after the step (frames may be throttled)
			if tip.shown && !tip.off {
				label, keys := hit_tip(ui_hover)
				got = keys != "" ? fmt.tprintf("%s %s", label, keys) : label
			}
			at.asserts += 1
			if got == rest do log("assert ok: tooltip", fmt.tprintf("%q", got))
			else do script_fail(fmt.tprintf("ASSERT FAILED tooltip: got %q, want %q (hover %v, shown %v, off %v)", got, rest, ui_hover, tip.shown, tip.off))
		case "assert_drawn", "assert_not_drawn":
			// TEXT is (not) in any text drawn now
			want_drawn := cmd == "assert_drawn"
			cmds := ui_layout(sapp.widthf(), sapp.heightf())
			found := false
			for i in 0 ..< cmds.length {
				c := &cmds.internalArray[i]
				if c.commandType != .Text do continue
				t := c.renderData.text
				if strings.contains(string(t.stringContents.chars[:t.stringContents.length]), rest) do found = true
			}
			app.redraw = true
			at.asserts += 1
			if want_drawn {
				if found do log("assert ok: drawn", fmt.tprintf("%q", rest))
				else do script_fail(fmt.tprintf("ASSERT FAILED drawn: %q is not on screen", rest))
			} else if !found do log("assert ok: not drawn", fmt.tprintf("%q", rest))
			else do script_fail(fmt.tprintf("ASSERT FAILED drawn: %q is on screen", rest))
		case "assert_md", "assert_not_md":
			got := md_shown_text()
			want := cmd == "assert_md"
			at.asserts += 1
			if strings.contains(got, rest) == want do log("assert ok:", cmd, fmt.tprintf("%q", rest))
			else do script_fail(fmt.tprintf("ASSERT FAILED %s %q (preview: %q)", cmd, rest, got[:min(len(got), 400)]))
		case "clickmd":
			x, y, ok := md_piece_point(rest)
			if !ok {
				script_fail("no preview text", rest)
				continue
			}
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
		case "assert_opened":
			at.asserts += 1
			if autotest.opened_url == rest do log("assert ok: opened", rest)
			else do script_fail(fmt.tprintf("ASSERT FAILED opened %q, want %q", autotest.opened_url, rest))
		case "clickmenu":
			// left click the open context menu's row labelled TEXT (as drawn last frame)
			if !menu.open {
				script_fail("ASSERT FAILED clickmenu: no menu is open, want", rest)
				continue
			}
			row := -1
			for it, i in menu_items() do if !it.sep && !it.note && it.label == rest {row = i; break}
			d := clay.GetElementData(clay.ID("menurow", u32(max(row, 0))))
			if row < 0 || !d.found {
				script_fail(fmt.tprintf("ASSERT FAILED clickmenu: no row %q in %s", rest, menu_rows_text()))
				continue
			}
			b := d.boundingBox
			x, y := b.x + b.width / 2, b.y + b.height / 2
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
		case "assert_menurows":
			// the open context menu's rows: labels joined by "|", "-" for a divider, notes left out
			got := menu.open ? menu_rows_text() : "<no menu>"
			at.asserts += 1
			if got == rest do log("assert ok: menu rows", got)
			else do script_fail(fmt.tprintf("ASSERT FAILED menu rows: %q, want %q", got, rest))
		case "assert_revealed":
			// the last path shown in Finder (platform.reveal, or a Reveal_In_Finder) contains TEXT; "-" = none since revealed_clear
			got := autotest.revealed != "" ? autotest.revealed : fs_model.revealed
			at.asserts += 1
			ok := rest == "-" ? got == "" : got != "" && strings.contains(got, rest)
			if ok do log("assert ok: revealed", got)
			else do script_fail(fmt.tprintf("ASSERT FAILED revealed: %q, want %q in it", got, rest))
		case "revealed_clear":
			delete(autotest.revealed)
			autotest.revealed = ""
			delete(fs_model.revealed)
			fs_model.revealed = ""
		case "assert_toast":
			// the toast showing now contains TEXT; "-" = none shows
			at.asserts += 1
			ok := rest == "-" ? toast.text == "" : toast.text != "" && strings.contains(toast.text, rest)
			if ok do log("assert ok: toast", fmt.tprintf("%q", toast.text))
			else do script_fail(fmt.tprintf("ASSERT FAILED toast: %q, want %q", toast.text, rest))
		case "toast_clear":
			toast_clear()
		case "assert_clipboard":
			// what pi-desk last put on the clipboard contains TEXT ("\n" = a line break); "-" = nothing since clipboard_clear
			want, _ := strings.replace_all(rest, `\n`, "\n", context.temp_allocator)
			at.asserts += 1
			ok := rest == "-" ? autotest.clipboard == "" : autotest.clipboard != "" && strings.contains(autotest.clipboard, want)
			if ok do log("assert ok: clipboard", fmt.tprintf("%q", autotest.clipboard))
			else do script_fail(fmt.tprintf("ASSERT FAILED clipboard: %q, want %q", autotest.clipboard, want))
		case "clipboard_clear":
			delete(autotest.clipboard)
			autotest.clipboard = ""
		case "assert_notice":
			e := tab_editor()
			got := e != nil ? e.notice : "<no editor>"
			at.asserts += 1
			if strings.contains(got, rest) do log("assert ok: notice", fmt.tprintf("%q", got))
			else do script_fail(fmt.tprintf("ASSERT FAILED notice: %q, want %q", got, rest))
		case "assert_files":
			// the shown tree's rows (Files or Settings; files_rows_text) contain TEXT ("\n" = a line break)
			want, _ := strings.replace_all(rest, `\n`, "\n", context.temp_allocator)
			got := files_rows_text(tree_rows())
			at.asserts += 1
			if strings.contains(got, want) do log("assert ok: files rows contain", fmt.tprintf("%q", want))
			else do script_fail(fmt.tprintf("ASSERT FAILED files rows: %q not in %q", want, got))
		case "assert_not_files":
			want, _ := strings.replace_all(rest, `\n`, "\n", context.temp_allocator)
			got := files_rows_text(tree_rows())
			at.asserts += 1
			if !strings.contains(got, want) do log("assert ok: files rows lack", fmt.tprintf("%q", want))
			else do script_fail(fmt.tprintf("ASSERT FAILED files rows: %q in %q", want, got))
		case "dragid":
			// a left drag from the centre of element FROM (index) to the centre of TO
			args := strings.fields(expand_vars(rest), context.temp_allocator)
			from := clay.GetElementData(clay.ID(args[0], u32(num(args[1]))))
			to := clay.GetElementData(clay.ID(args[2]))
			if !from.found || !to.found {
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
		case "files_time":
			// how long the Files tree takes to lay out N frames while scrolling by DY each (logical px)
			n, dy := int(num(args[0])), num(args[1])
			t0 := time.tick_now()
			for _ in 0 ..< n {
				files_ui.scroll += dy
				w, h := sapp.widthf(), sapp.heightf()
				ui_layout(w, h)
			}
			ms := time.duration_milliseconds(time.tick_since(t0))
			log(fmt.tprintf("FILES layout while scrolling: %d frames in %.1f ms (%.2f ms per frame), %d rows", n, ms, ms / f64(n), len(files_ui.rows)))
			app.redraw = true
		case "assert_rows":
			section, _, want := strings.partition(rest, " ")
			b := strings.builder_make(context.temp_allocator)
			switch section {
			case "open":
				for s, i in sidebar_open() {
					if i > 0 do strings.write_byte(&b, ',')
					strings.write_string(&b, open_session_title(s))
				}
			case "projects":
				for r, i in sidebar_projects() {
					if i > 0 do strings.write_byte(&b, ',')
					if r.project == nil do fmt.sbprintf(&b, "%s%s/", strings.repeat("+", r.depth, context.temp_allocator), r.name)
					else do fmt.sbprintf(&b, "%s%s", strings.repeat("+", r.depth, context.temp_allocator), project_name(r.project^))
				}
			case "sessions", "chats":
				for r, i in sidebar_sessions(section == "chats" ? .Chats : .Sessions) {
					if i > 0 do strings.write_byte(&b, ',')
					strings.write_string(&b, session_label(r.session^, section == "chats"))
				}
			case "tree":
				// as drawn in the last layout: projects, the expanded one's sessions as >title
				for id, i in drawn.proj {
					if i > 0 do strings.write_byte(&b, ',')
					if p := find_project(id); p != nil do strings.write_string(&b, project_name(p^))
					if id != state.selected_project do continue
					for sid in drawn.sess {
						for l in sessions_with_new(.Sessions, state.sessions[:]) do if l.id == sid do fmt.sbprintf(&b, ",>%s", session_label(l))
					}
				}
			}
			got := strings.to_string(b)
			if got == "" do got = "-"
			at.asserts += 1
			if got == want do log("assert ok: rows", section, "=", got)
			else do script_fail(fmt.tprintf("ASSERT FAILED rows %s: got %q, want %q", section, got, want))
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
			t := active_term()
			if t == nil do continue
			mt: gh.Mouse_Tracking
			gh.terminal_get(t.gt, .Mouse_Tracking, &mt)
			screen: gh.Terminal_Screen
			gh.terminal_get(t.gt, .Active_Screen, &screen)
			log(fmt.tprintf("mouse_tracking=%v sgr_1006=%v bracketed_paste_2004=%v focus_1004=%v sync_2026=%v color_scheme_2031=%v screen=%v cols=%d rows=%d", mt, mode_on(t, 1006), mode_on(t, 2004), mode_on(t, 1004), mode_on(t, 2026), mode_on(t, 2031), screen, t.cols, t.rows))
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
			sapp.set_clipboard_string(strings.clone_to_cstring(s, context.temp_allocator))
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
			send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x1, mouse_y = y1, modifiers = m})
			for i in 1 ..= 8 {
				f := f32(i) / 8
				send({type = .MOUSE_MOVE, mouse_x = x1 + (x2 - x1) * f, mouse_y = y1 + (y2 - y1) * f, modifiers = m})
			}
			send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x2, mouse_y = y2, modifiers = m})
		case "clicks":
			x, y := num(args[1]) * app.dpi, num(args[2]) * app.dpi
			for _ in 0 ..< int(num(args[0])) {
				send({type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
				send({type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y})
			}
		case "clickcell":
			t := active_term()
			if t == nil {
				script_fail("clickcell: no terminal")
				continue
			}
			cell := proc(t: ^Term, c, r: string) -> (f32, f32) {
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
			t := active_term()
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
		case "assert_link":
			// assert_link URL|-: the link underlined under the pointer (⌘ held), or none
			t := active_term()
			got := t != nil && t.link_on ? t.link.url : "-"
			at.asserts += 1
			if got == rest do log("assert ok: link", got)
			else do script_fail(fmt.tprintf("ASSERT FAILED link %q, want %q", got, rest))
		case "assert_drawn_selection":
			// assert_drawn_selection N: selected cells in the last frame drawn
			// (N > 0: "some"; 0: none)
			t := active_term()
			got := t != nil ? t.drawn_selected : -1
			want := int(num(args[0]))
			at.asserts += 1
			if (want == 0 && got == 0) || (want > 0 && got > 0) do log("assert ok: drawn selected cells =", got)
			else do script_fail(fmt.tprintf("ASSERT FAILED drawn selection: got %d cells, want %s", got, want > 0 ? "some" : "none"))
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
		case "assert_screen":
			at.asserts += 1
			if strings.contains(screen_text(), rest) do log("assert ok: on screen:", rest)
			else do script_fail(fmt.tprintf("ASSERT FAILED screen: %q not found", rest))
		case "assert_palette":
			rs := palette_results()
			i := int(num(args[0]))
			got := i < len(rs) ? rs[i].key : "<none>"
			at.asserts += 1
			if got == args[1] do log("assert ok: palette", i, "=", got)
			else do script_fail(fmt.tprintf("ASSERT FAILED palette %d: got %s, want %s", i, got, args[1]))
		case "assert_selection":
			got := ""
			if f, _, _ := focused_field(); f != nil do got = tf_selected_text(f)
			else if t := active_term(); t != nil do got = term_selection_text(t)
			at.asserts += 1
			if got == rest do log("assert ok: selection =", fmt.tprintf("%q", got))
			else do script_fail(fmt.tprintf("ASSERT FAILED selection: got %q, want %q", got, rest))
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
		case "hittest":
			got := test_hit(num(args[0]) * app.dpi, num(args[1]) * app.dpi)
			name := got == 1 ? "view" : (got == 0 ? "titlebar" : "nothing")
			at.asserts += 1
			if name == args[2] do log("assert ok: hit", args[0], args[1], "=", name)
			else do script_fail(fmt.tprintf("ASSERT FAILED hit %s %s: got %s, want %s", args[0], args[1], name, args[2]))
		case "system_appearance":
			// as if the OS switched (the platform's KVO callback path)
			on_system_appearance(args[0] == "light")
			inbox_drain()
		case "assert_in_window":
			// assert_in_window ID: the element is laid out, wholly inside the window
			_ = ui_layout(sapp.widthf(), sapp.heightf())
			d := clay.GetElementData(clay.ID(args[0]))
			b := d.boundingBox
			at.asserts += 1
			if d.found && b.x >= -0.5 && b.y >= -0.5 && b.x + b.width <= sapp.widthf() + 0.5 && b.y + b.height <= sapp.heightf() + 0.5 do log("assert ok: in window", args[0])
			else do script_fail(fmt.tprintf("ASSERT FAILED in window: %s at %v (found %v), window %vx%v", args[0], b, d.found, sapp.widthf(), sapp.heightf()))
		case "assert_window":
			// the window's own appearance (title bar, traffic lights, folder picker)
			got := test_window_light() ? "light" : "dark"
			at.asserts += 1
			if got == args[0] do log("assert ok: window appearance", got)
			else do script_fail(fmt.tprintf("ASSERT FAILED window appearance: got %s, want %s", got, args[0]))
		case "lights":
			x, y := test_light()
			log(fmt.tprintf("traffic lights: close button centre %.1f,%.1f; top bar centre y %.1f", x, y, f32(TAB_STRIP_H) / 2))
		case "copy":
			key_event("c", sapp.MODIFIER_SUPER)
			log("clipboard:", fmt.tprintf("%q", string(sapp.get_clipboard_string())))
		case "resize":
			window_set_content_size(num(args[0]), num(args[1]))
		case "shot":
			// An occluded window may not be composited: bring it forward
			// without taking keyboard focus, redraw, capture next step.
			window_raise_without_focus()
			app.redraw = true
			if t := active_term(); t != nil do t.changed = true
			at.pending_shot = strings.clone(args[0])
			at.wait_until = time.tick_add(now, 1000 * time.Millisecond)
			return
		case "dump":
			_ = os.write_entire_file(fmt.tprintf("build/%s.txt", args[0]), transmute([]u8)screen_text())
		case "cpu_begin":
			at.cpu_wall = now
			at.cpu_start = cpu_seconds()
			at.cpu_frames = app.frames_drawn
			at.cpu_bytes = total_bytes_in()
			at.cpu_calls = app.frames_called
		case "cpu_end":
			wall := time.duration_seconds(time.tick_diff(at.cpu_wall, now))
			cpu := cpu_seconds() - at.cpu_start
			calls := app.frames_called - at.cpu_calls
			log(fmt.tprintf("CPU %s: %.1f%% over %.1fs, %d frames drawn, %d frame callbacks (%.1f/s), %d pty bytes", rest, 100 * cpu / wall, wall, app.frames_drawn - at.cpu_frames, calls, f64(calls) / wall, total_bytes_in() - at.cpu_bytes))
		case "atlas":
			size, glyphs, rasterised, evictions, runs := font_stats()
			log(fmt.tprintf("atlas %dx%d px (%d KB), %d glyphs cached, %d rasterised, %d evictions, %d runs, mono %q %.0fpx cell %.0fx%.0f", size, size, int(size) * int(size) * 4 / 1024, glyphs, rasterised, evictions, runs, font.sets[.Mono].family, font.sets[.Mono].px, font.cell_w, font.cell_h))
		case "window":
			// as if the window went to the background or came to the front
			// (sokol's UNFOCUSED/FOCUSED; quiet test mode never gets them)
			send({type = args[0] == "back" ? .UNFOCUSED : .FOCUSED})
			inbox_drain()
		case "deactivate":
			app_deactivate()
		case "minimize":
			window_minimize()
		case "restore":
			window_restore()
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
		case "assert_menu":
			it := menubar_find(args[0])
			on, checked := menubar_state(menubar_tag(it)) // -1 when there is no such item: false, false
			got := args[1] == "enabled" || args[1] == "disabled" ? (on ? "enabled" : "disabled") : (checked ? "checked" : "unchecked")
			at.asserts += 1
			if it != nil && got == args[1] do log("assert ok: menu", args[0], got)
			else do script_fail(fmt.tprintf("ASSERT FAILED menu %s: got %s, want %s", args[0], it != nil ? got : "no such item", args[1]))
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
			inbox_drain()
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
			c, err := parse_command(text, context.temp_allocator)
			if err != "" {
				script_fail("command parse error:", err)
				continue
			}
			reply: Reply
			kind: Caller_Kind = cmd == "ui_command" ? .UI : cmd == "control_command" ? .Control : strings.has_prefix(cmd, "pi_") ? .Panel : .Script
			caller := Caller{kind = kind}
			if kind == .Panel do if cs := cur(); cs != nil do caller.tab_id = cs.tabs[0].id
			id := inbox_submit(c, caller, &reply)
			inbox_drain() // main thread: runs it now, in order with anything queued before
			r := reply.result
			delete(at.last_result)
			at.last_result = strings.clone(result_json(r))
			if r.created_id != 0 do at.prev_created, at.last_created = at.last_created, r.created_id
			if r.confirm_token != "" {
				delete(at.last_token)
				at.last_token = strings.clone(r.confirm_token)
			}
			log("result", id, at.last_result)
			result_free(r)
			if r.pending && cmd == "pi_command_bg" {
				at.bg_request, at.bg_done = id, false
				continue
			}
			if r.pending {
				at.wait_request = id
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
			c, err := parse_command(expand_vars(rest)) // heap: freed by the thread
			if err != "" {
				script_fail("command parse error:", err)
				continue
			}
			log("wakes so far:", app.wakes)
			pc := new_clone(c) // a Command is too big to pass by value
			thread.run_with_poly_data(pc, proc(pc: ^Command) {
				inbox_submit(pc^, {kind = .Control})
				command_free(pc^, context.allocator)
				free(pc)
			})
		case "wakes":
			log("wakes so far:", app.wakes)
		case "assert_state", "assert_result", "assert_finished":
			path, _, want := strings.partition(strings.trim_space(rest), " ")
			src := cmd == "assert_state" ? state_json() : cmd == "assert_finished" ? at.last_finished : at.last_result
			got := json_path(src, path)
			want = expand_vars(want)
			at.asserts += 1
			if got == want do log("assert ok:", path, "=", got)
			else do script_fail(fmt.tprintf("ASSERT FAILED %s: got %q, want %q", path, got, want))
		case "result_file": // result_file NAME: the last command's result to build/NAME.json
			_ = os.write_entire_file(fmt.tprintf("build/%s.json", args[0]), transmute([]u8)at.last_result)
		case "state_json":
			_ = os.write_entire_file(fmt.tprintf("build/%s.json", args[0]), transmute([]u8)state_json())
		case "quit":
			log(fmt.tprintf("done: %d asserts, %d failed", at.asserts, at.failures))
			app.quitting = true // the script ends the run: no confirmation
			sapp.request_quit()
			at.active = false
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
		case "app_open", "app_waitframe", "app_waitstatus", "app_waitlog", "assert_app_log", "assert_not_app_log", "assert_app_pixel", "app_square", "assert_app_moved", "app_mark", "app_waitring", "assert_app_surfaces", "assert_apps_freed", "app_click", "app_stats", "assert_app_dimmed", "app_keydown", "app_drag", "app_hover", "assert_app_hover", "assert_shot_pixel", "app_mouse", "app_leave":
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

@(private = "file")
script_fail :: proc(args: ..any) {
	autotest.failures += 1
	log(..args)
}

// Called for every event (events.odin).
autotest_on_event :: proc(ev: Event) {
	if f, ok := ev.(Finished_Event); ok && autotest.bg_request != 0 && f.request_id == autotest.bg_request {
		log("finished", f.request_id, result_json(f.result))
		delete(autotest.last_finished)
		autotest.last_finished = strings.clone(result_json(f.result))
		autotest.bg_done = true
	}
	if f, ok := ev.(Finished_Event); ok && autotest.wait_request != 0 && f.request_id == autotest.wait_request {
		log("finished", f.request_id, result_json(f.result))
		delete(autotest.last_finished)
		autotest.last_finished = strings.clone(result_json(f.result))
		autotest.wait_request = 0
	}
}

@(private = "file")
expand_vars :: proc(s: string) -> string {
	at := &autotest
	cs := cur()
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
		{"$hometab", fmt.tprint(home_tab() != nil ? home_tab().id : 0)},
		{"$tab", fmt.tprint(tab)},
		{"$chats", fmt.tprint(chats_project() != nil ? chats_project().id : 0)},
		{"$homedir", os.get_env("HOME", context.temp_allocator)},
		{"$notesdir", state.settings.home_dir},
		{"$datadir", home_root},
		{"$cwd", cwd},
	}
	out := s
	for v in vars do out, _ = strings.replace_all(out, v[0], v[1], context.temp_allocator)
	return out
}

// The value at a dotted path in a JSON document, as text: strings bare,
// numbers and bools as written, "#" = length of the array/object before it.
json_path :: proc(text, path: string) -> string {
	v, err := json.parse_string(text, .JSON, true, context.temp_allocator)
	if err != nil do return "<invalid json>"
	p := path
	for part in strings.split_iterator(&p, ".") {
		if part == "#" {
			#partial switch x in v {
			case json.Array:  return fmt.tprint(len(x))
			case json.Object: return fmt.tprint(len(x))
			}
			return "<not a list>"
		}
		#partial switch x in v {
		case json.Object:
			nv, ok := x[part]
			if !ok do return "<missing>"
			v = nv
		case json.Array:
			i, ok := strconv.parse_int(part)
			if !ok || i < 0 || i >= len(x) do return "<missing>"
			v = x[i]
		case:
			return "<missing>"
		}
	}
	#partial switch x in v {
	case json.String:  return x
	case json.Integer: return fmt.tprint(x)
	case json.Float:   return fmt.tprint(x)
	case json.Boolean: return x ? "true" : "false"
	case json.Null:    return "null"
	}
	return "<object>"
}

total_bytes_in :: proc() -> int {
	n := 0
	for _, t in terms do n += t.bytes_in
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
