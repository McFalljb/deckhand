package main

// Agents act on pages (docs/BROWSER.md §4, step 8): browser_click, browser_type, browser_press,
// browser_scroll, browser_select, browser_hover and browser_upload; the user's Take over / Hand
// back (browser_agent_take_over) and the upload bar's answer (browser_upload_answer).
//
// Who: as step 7's reads (table class Own_Session, browser_target): a pi tab acts only on its own
// session's browser tabs; Atlas and control callers on any. No site list (BROWSER.md §8 decision
// 4); actions are refused on file:, chrome:, devtools: and every page that is not http(s),
// about:blank or test mode's deckhand-test: (act_page_allowed).
//
// How: the input is CDP's Input domain (Input.dispatchMouseEvent, dispatchKeyEvent, insertText)
// through the tab's DevTools session, as the reads' Runtime.evaluate (cdp_send; our ids from
// AGENT_MSG_BASE up), not CEF's host input (dh_cef_mouse_click, dh_cef_key): that is the user's
// path (browser.odin's browser_event: held keys and buttons, the user's gesture for downloads),
// and CDP's coordinates are the page's CSS px whatever the tab's size, on screen or not.
// Finding targets and checking fields is src/native/browser_act.js in the overlay's isolated
// world (the page's scripts cannot patch what it calls). A tab not on screen is woken for the
// action (CEF un-hides it, as a screenshot does: a hidden page's pointer moves and wheel wait for
// a frame that never comes); the user's view never changes.
//
// The rules, here and in browser_act.js (never only in pi-kit):
//  - key input is checked right before it goes, one input per check: browser_type checks the
//    focused element once and inserts the whole text at once (Input.insertText, atomic; submit
//    is one Enter after a fresh check); browser_press sends one chord per check. Keys that
//    produce text (printable, without Cmd or Ctrl) go only to an allowlisted target in the top
//    document: a text, search, email, url, tel or number input, a textarea, or contenteditable
//    (through open shadow roots), and never a sensitive one: a password input, a field ever seen
//    as one (a "show password" button flips its type), -webkit-text-security, an autocomplete on
//    the field or its form naming a card (cc-*), a password or a one-time code, or a field inside
//    such an element (code sensitive_field). Focus inside an iframe (frame_focused), on a custom
//    element with a closed shadow root or an unknown element, or on nothing in particular
//    (not_a_field) is refused. Navigation keys (Tab, arrows, Enter, Escape, Page Up/Down,
//    Home/End) go anywhere, each after its own check; other keys (Backspace, shortcuts) anywhere
//    but a sensitive field, a frame or what cannot be checked;
//  - every check ends the action with page_changed once the page is not the one it started on:
//    a main-frame navigation started or committed, the address or origin changed, or our
//    world's context is another (so "Enter a b c" on a submitting form stops after Enter);
//  - screenshots are refused (sensitive_visible) while a revealed password field shows text
//    (browser_agent.odin; browser_act.js revealed);
//  - an upload shows a bar on the tab ("<agent> wants to upload <full paths> to <origin>": Allow /
//    Block, the bars' click guard): nothing is sent before Allow; files are checked when asked
//    and again at Allow (regular files only; never a symbolic link, nor anything under ~/.ssh,
//    ~/.gnupg, ~/Library/Keychains, ~/.aws, ~/.config/gh, ~/.netrc, ~/.pi or Deckhand's own data
//    and browser profile: path_not_allowed); the bar's origin is checked again at Allow and
//    right before the files go, to an <input type=file> only; unanswered in ACT_UPLOAD_WAIT:
//    waiting_for_user. While the bar asks, the tab takes no other agent action (busy);
//  - a native file chooser opened during an agent's action is cancelled (use_browser_upload);
//  - the clipboard: its change count is noted when an action's input goes; a page that changed
//    it meanwhile is told to the user (toast, bell) and the agent ("clipboard_changed": true);
//    nothing is put back;
//  - an agent's input is never the user's gesture: browser_page_input is not called, and a
//    gesture the user just made is used up when an agent's action is accepted, so a download an
//    agent's click starts asks first (the result says "download":"waiting_for_user");
//  - no JavaScript evaluation for agents (BROWSER.md: deliberately left out);
//  - an agent's popup opens behind (on_cef_popup), its right-click opens no Deckhand menu.
//
// The user: the agent strip (browser_agent.odin) says what the agent does ("pi is clicking
// 'Buy'") with Take over and Stop, and a brief ring marks each click. Stop ends the tab's running
// and queued actions (stopped). Take over (or the user's own click or key in the page while an
// action runs) pauses agents on the tab until Hand back: every agent call on it returns
// user_has_control at once. A tab not on screen that an agent acts on shows a dot in the tab bar
// and "pi is using a page" (or Claude, or Atlas: whoever acted) on its session's sidebar row (both
// linger ACT_LINGER after the last).
//
// Actions on one tab run one at a time, in order (the others wait); each has ACT_TIMEOUT from
// when Deckhand accepted it. A requester's cancel (socket.odin's cancel line) or its connection
// closing ends its actions (cancelled).

import "core:c"
import "core:encoding/json"
import "core"
import jg "jsonguard"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import sapp "../vendor/sokol-odin/sokol/app"

BROWSER_ACT_JS :: #load("native/browser_act.js", string)
ACT_INIT_JS :: "(" + BROWSER_ACT_JS + `)({"op":"init"})` // the password tracker (browser_annotate.odin: every document)
ACT_TIMEOUT :: 30 * time.Second // an action, from when Deckhand accepted it (time queued counts)
ACT_UPLOAD_WAIT :: 120 * time.Second // the upload bar waits this long for the user
ACT_SETTLE :: 300 * time.Millisecond // after the input: a navigation, a download or a dialog starts
ACT_NAV_WAIT :: 5 * time.Second // a navigation the action started: its load, at most this long
ACT_KEY_GAP :: 50 * time.Millisecond // between two chords of browser_press (each checked)
ACT_ENTER_GAP :: 300 * time.Millisecond // after an Enter: a form it submitted starts navigating
ACT_LINGER :: 5 * time.Second // the tab's dot and the sidebar's "… is using a page" after the last action
ACT_TEXT_MAX :: 5000 // bytes browser_type types at most
ACT_KEYS_MAX :: 50 // chords browser_press presses at most
ACT_FILES_MAX :: 20
ACT_MARK_FOR :: 800 * time.Millisecond // the ring at a click
// CDP's modifier bits
ACT_MOD_ALT :: 1
ACT_MOD_CONTROL :: 2
ACT_MOD_META :: 4
ACT_MOD_SHIFT :: 8

ACT_USER_HAS_CONTROL :: "the user has taken over this tab (Take over, or their own click or key in it while you acted): stop using it and wait for the user, who hands it back with Hand back"
ACT_SENSITIVE :: "this is a password, card or one-time-code field (or inside one): agents never type, press keys or choose there. Ask the user to press Take over on the page and enter it themselves"

// ---- commands (rows in command_table.odin) ----



// ---- keys (pure) ----

Act_Key :: struct {
	key:     string, // DOM key
	code:    string, // DOM code
	text:    string, // what it types ("" = nothing)
	command: string, // an editing command macOS's key path needs (selectAll, deleteBackward)
	vk:      int, // windowsVirtualKeyCode
	mods:    int,
}

// Chords, space separated ("Tab", "Shift+Tab", "Meta+A", "ArrowDown ArrowDown Enter"): named keys,
// one ASCII letter, digit or punctuation mark, with Shift, Control (Ctrl), Alt (Option) and Meta
// (Cmd, Command). Meta+C, Meta+V and Meta+X are refused: the clipboard is the user's.
act_keys_parse :: proc(keys: string) -> (out: []Act_Key, err: string) {
	list := make([dynamic]Act_Key, context.temp_allocator)
	for chord in strings.fields(keys, context.temp_allocator) {
		if len(list) >= ACT_KEYS_MAX do return nil, fmt.tprintf("at most %d keys a call", ACT_KEYS_MAX)
		parts := strings.split(chord, "+", context.temp_allocator)
		k: Act_Key
		for p, i in parts {
			if p == "" do return nil, fmt.tprintf("%q: an empty key name", chord)
			if i < len(parts) - 1 {
				switch strings.to_lower(p, context.temp_allocator) {
				case "shift":                     k.mods |= ACT_MOD_SHIFT
				case "control", "ctrl":           k.mods |= ACT_MOD_CONTROL
				case "alt", "option":             k.mods |= ACT_MOD_ALT
				case "meta", "cmd", "command":    k.mods |= ACT_MOD_META
				case: return nil, fmt.tprintf("%q: %q is not a modifier (Shift, Control, Alt, Meta)", chord, p)
				}
				continue
			}
			ok: bool
			k, ok = act_key_named(p, k.mods)
			if !ok do return nil, fmt.tprintf("%q: %q is not a key Deckhand knows (named keys: Enter, Tab, Escape, Backspace, Delete, Space, ArrowUp/Down/Left/Right, Home, End, PageUp, PageDown, F1-F12; or one letter, digit or punctuation mark)", chord, p)
		}
		if k.mods & ACT_MOD_META != 0 && (k.code == "KeyC" || k.code == "KeyV" || k.code == "KeyX") do return nil, fmt.tprintf("%q: copy, cut and paste are refused (the clipboard is the user's)", chord)
		if k.mods & ACT_MOD_META != 0 && k.code == "KeyA" do k.command = "selectAll"
		append(&list, k)
	}
	if len(list) == 0 do return nil, "keys is empty (e.g. \"Enter\", \"Shift+Tab\")"
	return list[:], ""
}

@(private = "file")
act_key_named :: proc(name: string, mods: int) -> (k: Act_Key, ok: bool) {
	k.mods = mods
	typing := mods & (ACT_MOD_CONTROL | ACT_MOD_ALT | ACT_MOD_META) == 0 // a chord with them types nothing
	named :: proc(k: ^Act_Key, key, code: string, vk: int, text := "", command := "") {
		k.key, k.code, k.vk, k.text, k.command = key, code, vk, text, command
	}
	switch name {
	case "Enter", "Return": named(&k, "Enter", "Enter", 13, "\r")
	case "Tab":             named(&k, "Tab", "Tab", 9)
	case "Escape", "Esc":   named(&k, "Escape", "Escape", 27)
	case "Backspace":       named(&k, "Backspace", "Backspace", 8, "", "deleteBackward")
	case "Delete":          named(&k, "Delete", "Delete", 46, "", "deleteForward")
	case "Space":           named(&k, " ", "Space", 32, " ")
	case "ArrowUp":         named(&k, "ArrowUp", "ArrowUp", 38)
	case "ArrowDown":       named(&k, "ArrowDown", "ArrowDown", 40)
	case "ArrowLeft":       named(&k, "ArrowLeft", "ArrowLeft", 37)
	case "ArrowRight":      named(&k, "ArrowRight", "ArrowRight", 39)
	case "Home":            named(&k, "Home", "Home", 36)
	case "End":             named(&k, "End", "End", 35)
	case "PageUp":          named(&k, "PageUp", "PageUp", 33)
	case "PageDown":        named(&k, "PageDown", "PageDown", 34)
	case "Insert":          named(&k, "Insert", "Insert", 45)
	case:
		if len(name) >= 2 && len(name) <= 3 && name[0] == 'F' {
			n := 0
			for ch in transmute([]u8)name[1:] {
				if ch < '0' || ch > '9' do return {}, false
				n = n * 10 + int(ch - '0')
			}
			if n < 1 || n > 12 do return {}, false
			named(&k, name, name, 111 + n)
			break
		}
		if len(name) != 1 do return {}, false
		ch := name[0]
		switch {
		case ch >= 'a' && ch <= 'z', ch >= 'A' && ch <= 'Z':
			lower := ch | 0x20
			up := lower - 32
			shown := mods & ACT_MOD_SHIFT != 0 || (ch >= 'A' && ch <= 'Z') ? up : lower
			k.key = strings.clone(string([]u8{shown}), context.temp_allocator)
			k.code = fmt.tprintf("Key%c", rune(up))
			k.vk = int(up)
		case ch >= '0' && ch <= '9':
			k.key = strings.clone(name, context.temp_allocator)
			k.code = fmt.tprintf("Digit%c", rune(ch))
			k.vk = int(ch)
		case:
			PUNCT :: "-=,./;'[]\\`"
			CODES := [?]string{"Minus", "Equal", "Comma", "Period", "Slash", "Semicolon", "Quote", "BracketLeft", "BracketRight", "Backslash", "Backquote"}
			VKS := [?]int{189, 187, 188, 190, 191, 186, 222, 219, 221, 220, 192}
			i := strings.index_byte(PUNCT, ch)
			if i < 0 do return {}, false
			k.key = strings.clone(name, context.temp_allocator)
			k.code, k.vk = CODES[i], VKS[i]
		}
		if typing do k.text = k.key
	}
	if !typing && k.text != "\r" do k.text = ""
	if !typing do k.text = ""
	return k, true
}

// Pages actions may run on: http(s), about:blank and test mode's fixtures. Never file: (the
// user's), chrome:, devtools:, view-source:, extensions, data: or anything else.
act_page_allowed :: proc(url: string) -> bool {
	u := strings.to_lower(url, context.temp_allocator)
	if strings.has_prefix(u, "https://") || strings.has_prefix(u, "http://") || strings.has_prefix(u, "deckhand-test://") do return true
	return u == "about:blank" || strings.has_prefix(u, "about:blank#") || strings.has_prefix(u, "about:blank?")
}

// An upload's files: absolute paths of regular files (a symlink to one counts; a directory,
// device or anything else never), at most ACT_FILES_MAX. "" = fine.
act_files_check :: proc(paths: []string) -> (code, err: string) {
	if len(paths) == 0 do return "bad_file", "paths is empty (absolute paths of the files to upload)"
	if len(paths) > ACT_FILES_MAX do return "bad_file", fmt.tprintf("at most %d files", ACT_FILES_MAX)
	for p in paths {
		if !filepath.is_abs(p) do return "bad_file", fmt.tprintf("%q is not an absolute path", p)
		// protected folders first (by name: nothing there is opened or even looked at)
		clean, _ := filepath.clean(p, context.temp_allocator)
		if act_path_protected(clean) do return "path_not_allowed", fmt.tprintf("%s is in a folder agents never upload from (keys, credentials, pi's and Deckhand's own files)", act_path_shown(clean))
		// a symlink (the file itself) goes nowhere else; any folder link is followed for the check
		if li, lerr := os.lstat(clean, context.temp_allocator); lerr == nil && li.type == .Symlink {
			return "path_not_allowed", fmt.tprintf("%s is a symbolic link: give the file's real path", act_path_shown(clean))
		}
		if real, rok := act_real_path(clean); rok && act_path_protected(real) {
			return "path_not_allowed", fmt.tprintf("%s is in a folder agents never upload from (through a link)", act_path_shown(clean))
		}
		fi, serr := os.stat(p, context.temp_allocator)
		if serr != nil do return "bad_file", fmt.tprintf("%q does not exist (or cannot be read)", p)
		if fi.type != .Regular do return "bad_file", fmt.tprintf("%q is not a regular file (directories and devices are never uploaded)", p)
		// a hard link is another name for a file that may be anywhere (a key under ~/.ssh)
		st: posix.stat_t
		if posix.stat(strings.clone_to_cstring(clean, context.temp_allocator), &st) == .OK && st.st_nlink > 1 {
			return "path_not_allowed", fmt.tprintf("%s has other names (hard links): agents never upload such a file", act_path_shown(clean))
		}
	}
	return "", ""
}



// Folders agents never upload from: keys and credentials, pi's own, Deckhand's data and browser
// profile. path is clean and absolute.
act_path_protected :: proc(path: string) -> bool {
	home := os.get_env("HOME", context.temp_allocator)
	under :: proc(path, dir: string) -> bool {
		if dir == "" || dir == "/" do return false
		d := strings.trim_right(dir, "/")
		return path == d || strings.has_prefix(path, strings.concatenate({d, "/"}, context.temp_allocator))
	}
	dirs := make([dynamic]string, context.temp_allocator)
	if home != "" {
		for sub in ([]string {
			".ssh", ".gnupg", "Library/Keychains", ".aws", ".config/gh", ".netrc", ".pi",
			".git-credentials", ".docker", ".kube", ".npmrc",
			// browsers' profiles (cookies, saved passwords)
			"Library/Application Support/Google/Chrome", "Library/Application Support/Chromium",
			"Library/Application Support/Firefox", ".mozilla", "Library/Safari",
			"Library/Containers/com.apple.Safari", "Library/Cookies",
		}) {
			append(&dirs, fmt.tprintf("%s/%s", strings.trim_right(home, "/"), sub))
		}
	}
	append(&dirs, core.data_dir(context.temp_allocator), browser_profile_root(context.temp_allocator))
	if home != "" { // both of the data dir's places (the rename: platform.odin data_dir_names)
		new, old := core.data_dir_names(home)
		append(&dirs, new, old)
	}
	for d in dirs {
		if under(path, d) do return true
		// the folder's own real path too (a home folder behind a link)
		if real, ok := act_real_path(d); ok && under(path, real) do return true
	}
	return false
}

// The real path (links resolved), when it exists.
act_real_path :: proc(path: string) -> (string, bool) {
	buf: [posix.PATH_MAX]u8
	r := posix.realpath(strings.clone_to_cstring(path, context.temp_allocator), raw_data(buf[:]))
	if r == nil do return "", false
	return strings.clone(string(cstring(raw_data(buf[:]))), context.temp_allocator), true
}

// A path as the upload bar shows it: on one line, ~ for the home folder.
act_path_shown :: proc(path: string) -> string {
	home := strings.trim_right(os.get_env("HOME", context.temp_allocator), "/")
	p := path
	if home != "" && (p == home || strings.has_prefix(p, strings.concatenate({home, "/"}, context.temp_allocator))) do p = strings.concatenate({"~", p[len(home):]}, context.temp_allocator)
	return core.one_line(p, context.temp_allocator)
}

// ---- runtime ----

Act_Kind :: enum u8 {
	Click,
	Type,
	Press,
	Scroll,
	Select,
	Hover,
	Upload,
}
ACT_KIND_NOUNS := [Act_Kind]string {
	.Click  = "click",
	.Type   = "typing",
	.Press  = "keys",
	.Scroll = "scrolling",
	.Select = "choice",
	.Hover  = "hover",
	.Upload = "upload",
}
ACT_KIND_NAMES := [Act_Kind]string {
	.Click  = "click",
	.Type   = "type",
	.Press  = "press",
	.Scroll = "scroll",
	.Select = "select",
	.Hover  = "hover",
	.Upload = "upload",
}
Act_Stage :: enum u8 {
	Page, // waiting for its turn, the page and its isolated world
	Locate, // the target (browser_act.js target / select / check)
	Scroll_Before, // scroll offsets before a wheel
	Check, // the focused element (and the page) checked right before the next input
	Send, // input events in flight
	Gap, // between two chords (browser_press): the next check waits
	Settle, // a navigation, download or dialog the input started
	Scroll_After,
	Bar, // the upload bar asks the user
	File_El, // the file input as an object
	Set_Files,
}

Act_Op :: struct {
	request_id:  u64,
	tab_id:      u64,
	kind:        Act_Kind,
	who:         core.Caller_Kind,
	who_tab:     u64, // the caller's own tab (a pi or Claude tab; Atlas's), 0: none
	who_text:    string, // owned: the upload bar's "<agent>"
	stage:       Act_Stage,
	active:      bool, // its turn came (its deadline counts from its acceptance)
	selector:    string, // owned
	x, y:        f32,
	has_xy:      bool,
	button:      core.Act_Button,
	double:      bool,
	mods:        int,
	text:        string, // owned (type)
	clear:       bool,
	submit:      bool,
	keys:        string, // owned (press)
	dx, dy:      f32,
	label:       string, // owned
	value:       string, // owned
	has_label:   bool,
	paths:       [dynamic]string, // owned
	started:     time.Tick,
	deadline:    time.Tick,
	settle_at:   time.Tick,
	bar_at:      time.Tick,
	msg_id:      c.int, // one call in flight (an evaluate)
	cef:         c.int,
	reply:       string, // owned
	reply_ok:    bool,
	first_id:    c.int, // a batch of input events in flight: their ids
	last_id:     c.int,
	outstanding: int,
	send_err:    string, // owned: a batch's first failure
	hit:         string, // owned: the target as JSON ({role, name, tag, ref?}), page data
	px, py:      f64, // the point the input went to
	pos:         int, // bytes of text (type) sent
	inserted:    bool, // the text (or a clear) went
	sent_keys:   int,
	submitted:   bool,
	nav0:        time.Tick, // the tab's last new document before the input
	navs0:       time.Tick, // the last main-frame navigation's start before the input
	ctx0:        i64, // our world's context when the target was found (another: a new document)
	url0:        string, // owned
	origin:      string, // owned: the upload bar's origin (the page's when it asked)
	js_origin:   string, // owned: the same as the page itself says it (location.origin)
	file_dialog: bool, // a native file chooser opened under the action (cancelled)
	clip0:       int, // the clipboard's change count when the action's input first went
	clip_armed:  bool, // clip0 is set (the upload bar's wait never counts)
	dl0:         u32, // a download asking before the input
	popup:       u64, // a popup the input opened
	scroll0:     string, // owned
	answer:      i8, // the upload bar: 1 Allow, -1 Block
	object_id:   string, // owned
	multiline:   bool,
}

act_ops: [dynamic]^Act_Op
act_linger: map[u64]time.Tick // tab -> when its last action ended (the dot and the sidebar line linger)
act_test_finished: ^map[u64]string // tests: every finished result by request id

// An action is running or queued on the tab.
browser_act_busy :: proc(tab_id: u64) -> bool {
	for op in act_ops do if op.tab_id == tab_id do return true
	return false
}

// The tab's action now (its turn), or nil.
@(private = "file")
act_head :: proc(tab_id: u64) -> ^Act_Op {
	for op in act_ops do if op.tab_id == tab_id do return op
	return nil
}

// The upload asking on the tab (its bar shows), or nil.
act_upload_asking :: proc(tab_id: u64) -> ^Act_Op {
	op := act_head(tab_id)
	return op != nil && op.stage == .Bar ? op : nil
}

// CEF should paint the hidden tab: an action works on it (not while it waits for the user).
browser_act_waking :: proc(tab_id: u64) -> bool {
	op := act_head(tab_id)
	return op != nil && op.active && op.stage != .Bar
}

// An agent acts on the tab, or did in the last ACT_LINGER (the tab's dot).
browser_act_recent :: proc(tab_id: u64) -> bool {
	if browser_act_busy(tab_id) do return true
	at, has := act_linger[tab_id]
	return has && time.tick_since(at) < ACT_LINGER
}

// Some browser tab of the session that is not on screen has an agent acting on it (or did in
// the last ACT_LINGER).
browser_act_session_background :: proc(s: ^core.Open_Session) -> bool {
	_, ok := browser_act_background_tab(s)
	return ok
}

// Which such tab (the one acted on last).
@(private = "file")
browser_act_background_tab :: proc(s: ^core.Open_Session) -> (tab_id: u64, ok: bool) {
	seen := make(map[u64]bool, context.temp_allocator)
	for op in act_ops do seen[op.tab_id] = true
	for id, at in act_linger do if time.tick_since(at) < ACT_LINGER do seen[id] = true
	best: time.Tick
	for id in seen {
		os_, tab, _ := find_tab(id)
		if os_ == nil || os_.id != s.id || tab == nil do continue
		if core.tab_on_screen(tab.id) do continue // the user sees it (any pane)
		at := agent_tab_of(id)
		last := at != nil ? at.last : time.Tick{}
		if !ok || time.tick_diff(best, last) > 0 do tab_id, best, ok = id, last, true
	}
	return
}

// The sidebar row's text while an agent acts in a tab of s not on screen ("" = none).
browser_act_session_text :: proc(s: ^core.Open_Session) -> string {
	id, ok := browser_act_background_tab(s)
	if !ok do return ""
	// the agent that acted (a Claude tab in a pi session is Claude), else the session's harness
	who := s.agent == .Claude ? "Claude" : "pi"
	if at := agent_tab_of(id); at != nil && (at.who == .Panel || at.who == .Control) do who = agent_who(at.who, at.who_claude)
	return fmt.tprintf("%s is using a page", who)
}

// A native file chooser is opening in the tab (cef_polish.inc's dialog handler): while an agent's
// action runs there it is cancelled (true) and the action ends with use_browser_upload; within
// ACT_LINGER after one too, unless the user clicked or typed in the page since; the user's own
// click gets the panel (false).
browser_act_file_dialog :: proc(tab_id: u64) -> bool {
	op := act_head(tab_id)
	if op == nil {
		// shortly after an agent's action (a chooser its click opened late): the agent's, unless
		// the user clicked or typed in the page since
		at, has := act_linger[tab_id]
		if !has || time.tick_since(at) >= ACT_LINGER do return false
		if p := page_extras[tab_id]; p != nil && p.input_at != {} && time.tick_diff(at, p.input_at) >= 0 do return false
		fmt.printfln("[browser] tab %d: a file chooser right after an agent's action was cancelled", tab_id)
		toast_show("A file chooser the agent's click opened was cancelled (agents upload through the upload bar)")
		return true
	}
	if op.stage == .Bar do return false
	op.file_dialog = true
	app.redraw = true
	fmt.printfln("[browser] tab %d: a file chooser under an agent's action was cancelled", tab_id)
	return true
}

// The requester cancelled its request, or its connection closed (socket.odin): that action or
// agent read ends (code cancelled).
act_request_cancel :: proc(c: core.Request_Cancel) -> core.Result {
	why := c.closed ? "the requester's connection closed" : "cancelled by the requester"
	for op in act_ops do if op.request_id == c.request_id {
		act_end(op, code_err("cancelled", why))
		return {ok = true}
	}
	if agent_request_end(c.request_id, why, "cancelled") do return {ok = true}
	return core.fail("no running request with that id")
}

@(private = "file")
act_free :: proc(op: ^Act_Op) {
	delete(op.who_text)
	delete(op.selector)
	delete(op.text)
	delete(op.keys)
	delete(op.label)
	delete(op.value)
	for p in op.paths do delete(p)
	delete(op.paths)
	delete(op.reply)
	delete(op.send_err)
	delete(op.hit)
	delete(op.url0)
	delete(op.origin)
	delete(op.js_origin)
	delete(op.scroll0)
	delete(op.object_id)
	free(op)
}

@(private = "file")
own :: proc(dst: ^string, v: string) {
	if dst^ == v do return
	delete(dst^)
	dst^ = strings.clone(v)
}

// A finished action's answer (tests also keep it: act_test_finished).
act_finish :: proc(request_id: u64, r: core.Result, private := false) {
	if act_test_finished != nil do act_test_finished[request_id] = strings.clone(core.result_json(r))
	tab_host_finished(request_id, r, private)
}

@(private = "file")
code_err :: proc(code, msg: string) -> core.Result {
	return {error = msg, data = fmt.tprintf(`{{"code":"%s"}}`, code)}
}

// Ends op (removed from the list): its answer goes. A clipboard the page changed meanwhile is
// told to the user (toast, bell) and the agent (clipboard_changed in the result).
@(private = "file")
act_end :: proc(op: ^Act_Op, r: core.Result, private := false) {
	// the page changed the clipboard while the input went in: the user hears it (nothing is
	// put back: the clipboard may hold what a password manager just cleared)
	if act_clip_changed(op) {
		origin := op.origin != "" ? op.origin : op.url0 != "" ? url_origin(op.url0) : "the page"
		msg := fmt.tprintf("%s changed your clipboard during pi's %s", origin, ACT_KIND_NOUNS[op.kind])
		fmt.printfln("[browser] tab %d: %s", op.tab_id, msg)
		toast_show(msg)
		core.notify_page_clipboard(op.tab_id, msg)
	}
	for x, i in act_ops do if x == op {
		ordered_remove(&act_ops, i)
		break
	}
	act_linger[op.tab_id] = time.tick_now()
	act_finish(op.request_id, r, private)
	tab_id := op.tab_id
	act_free(op)
	agent_unwake(tab_id)
	if t := agent_tab_of(tab_id); t != nil {
		if t.last != {} do t.last = time.tick_now() // the strip lingers from the end (naming the last target)
	}
	app.redraw = true
}

// Every action of the tab (running and queued) ends with this error (Stop, Take over, the user's
// own input).
browser_act_cancel :: proc(tab_id: u64, msg, code: string) {
	for {
		op := act_head(tab_id)
		if op == nil do break
		act_end(op, code_err(code, msg))
	}
}

// The user's own click or key in the page (browser.odin, before it is forwarded): while an
// agent's action runs there (not one waiting for the user's answer), agents pause on the tab as
// for Take over.
browser_act_user_input :: proc(tab_id: u64) {
	op := act_head(tab_id)
	if op == nil || op.stage == .Bar do return
	fmt.printfln("[browser] tab %d: the user's click or key while an agent acted: agents paused until Hand back", tab_id)
	agent_take_over(tab_id, true)
}

// A popup opened from the tab while an agent acted (on_cef_popup: it opened behind).
browser_act_popup :: proc(opener, tab_id: u64) {
	if op := act_head(opener); op != nil do op.popup = tab_id
}

// The pane of s a popup of tab `opener` goes into: while an agent's action runs there (its click
// opened it), the acting agent's own pane (open_pane); else 0, the focused pane.
browser_popup_pane :: proc(s: ^core.Open_Session, opener: u64) -> u64 {
	op := act_head(opener)
	if op == nil do return 0
	return core.open_pane(s, {kind = op.who, tab_id = op.who_tab})
}

// Every action gone, unanswered (unit tests).
browser_act_reset :: proc() {
	for op in act_ops do act_free(op)
	clear(&act_ops)
	clear(&act_linger)
}

// tests: the tab's upload goes straight to its bar, as if the page had answered
act_test_to_bar :: proc(tab_id: u64) -> bool {
	op := act_head(tab_id)
	if op == nil || op.kind != .Upload do return false
	op.active = true
	op.stage = .Bar
	op.bar_at = time.tick_now()
	op.deadline = time.tick_add(op.bar_at, ACT_UPLOAD_WAIT)
	own(&op.hit, `{"role":"file input","name":"Attachment","tag":"input"}`)
	if _, tab, _ := find_tab(tab_id); tab != nil {
		if bt, is := tab.kind.(core.Browser_Tab); is do own(&op.origin, url_origin(bt.url))
	}
	return true
}

// ---- commands ----

browser_act_apply :: proc(cmd: core.Command, caller: core.Caller, request_id: u64) -> (r: core.Result, changed: bool) {
	#partial switch c in cmd {
	case core.Browser_Upload_Answer:
		op := act_upload_asking(c.tab_id)
		if op == nil do return core.fail("no upload is asking on this tab"), false
		if !c.allow {
			fmt.printfln("[browser] tab %d: upload blocked by the user", c.tab_id)
			act_end(op, code_err("upload_blocked", "the user pressed Block on the upload bar: nothing was sent"))
			return {ok = true}, true
		}
		if code, err := act_files_check(op.paths[:]); err != "" {
			act_end(op, code_err(code, fmt.tprintf("%s (checked again at Allow): nothing was sent", err)))
			return {ok = true}, true
		}
		// the page the bar named: still on that origin
		if _, tab, _ := find_tab(c.tab_id); tab != nil {
			bt, _ := tab.kind.(core.Browser_Tab)
			if url_origin(bt.url) != op.origin {
				act_end(op, code_err("page_changed", "the page moved to another site while the upload bar asked: nothing was sent"))
				return {ok = true}, true
			}
		}
		fmt.printfln("[browser] tab %d: upload allowed by the user (%d files)", c.tab_id, len(op.paths))
		op.stage = .File_El
		now := time.tick_now()
		op.deadline = time.tick_add(now, ACT_TIMEOUT) // the files go now: a fresh timeout from Allow
		app.redraw = true
		return {ok = true}, true
	case core.Request_Cancel:
		return act_request_cancel(c), true
	case core.Browser_Agent_Take_Over:
		_, _, _, err := core.browser_target(caller, c.tab_id)
		if err != "" do return core.fail(err), false
		agent_take_over(c.tab_id, c.on)
		return {ok = true}, true
	}
	tab_id := core.browser_act_command_tab(cmd)
	_, _, bt, err := core.browser_target(caller, tab_id)
	if err != "" do return core.fail(err), false
	if r, refused := browser_agent_refused(caller, tab_id); refused do return r, false
	if act_upload_asking(tab_id) != nil do return code_err("busy", "the upload bar on this tab is asking the user: wait for their answer (the upload's own result), then act"), false
	if !act_page_allowed(bt.url) do return code_err("page_not_allowed", "agents do not act on this page (file:, chrome:, devtools: and other browser pages are the user's)"), false
	target_ok :: proc(tg: core.Act_Target, need: bool) -> (core.Result, bool) {
		if tg.selector != "" && tg.has_xy do return code_err("bad_args", "a target is selector or x,y, not both"), false
		if need && tg.selector == "" && !tg.has_xy do return code_err("bad_args", "a target is needed: selector (a ref=eN or a simple selector) or x,y"), false
		if tg.selector != "" && !agent_selector_ok(tg.selector) do return {error = AGENT_SELECTOR_UNSUPPORTED, data = `{"code":"selector_unsupported"}`}, false
		if tg.has_xy && (tg.x < 0 || tg.y < 0 || tg.x > 100_000 || tg.y > 100_000) do return code_err("bad_args", "x,y are the page's CSS px from the viewport's top-left (not negative)"), false
		return {}, true
	}
	sel_ok :: proc(sel: string, need: bool) -> (core.Result, bool) {
		if need && sel == "" do return code_err("bad_args", "selector is needed (a ref=eN or a simple selector)"), false
		if sel != "" && !agent_selector_ok(sel) do return {error = AGENT_SELECTOR_UNSUPPORTED, data = `{"code":"selector_unsupported"}`}, false
		return {}, true
	}
	op := new(Act_Op)
	op.request_id, op.tab_id, op.who, op.who_tab = request_id, tab_id, caller.kind, caller.tab_id
	op.deadline = time.tick_add(time.tick_now(), ACT_TIMEOUT) // from acceptance: a queued action waits on its own clock
	doing: Agent_Doing
	bad: core.Result
	ok := true
	#partial switch c in cmd {
	case core.Browser_Click:
		if bad, ok = target_ok(c.target, true); ok {
			op.kind, doing = .Click, .Clicking
			op.selector, op.x, op.y, op.has_xy = strings.clone(c.target.selector), c.target.x, c.target.y, c.target.has_xy
			op.button, op.double, op.mods = c.button, c.double, c.modifiers
		}
	case core.Browser_Hover:
		if bad, ok = target_ok(c.target, true); ok {
			op.kind, doing = .Hover, .Hovering
			op.selector, op.x, op.y, op.has_xy = strings.clone(c.target.selector), c.target.x, c.target.y, c.target.has_xy
		}
	case core.Browser_Scroll:
		if bad, ok = target_ok(c.target, false); ok {
			if c.target.selector == "" && c.dx == 0 && c.dy == 0 do bad, ok = code_err("bad_args", "nothing to scroll: dx or dy (CSS px), or a selector to bring into view"), false
			else if abs(c.dx) > 100_000 || abs(c.dy) > 100_000 do bad, ok = code_err("bad_args", "dx and dy are at most 100000 px"), false
		}
		if ok {
			op.kind, doing = .Scroll, .Scrolling
			op.selector, op.x, op.y, op.has_xy = strings.clone(c.target.selector), c.target.x, c.target.y, c.target.has_xy
			op.dx, op.dy = c.dx, c.dy
		}
	case core.Browser_Type:
		if bad, ok = sel_ok(c.selector, false); ok {
			if c.text == "" && !c.submit && !c.clear do bad, ok = code_err("bad_args", "text is needed"), false
			else if len(c.text) > ACT_TEXT_MAX do bad, ok = code_err("bad_args", fmt.tprintf("text is at most %d bytes a call", ACT_TEXT_MAX)), false
			else if !utf8.valid_string(c.text) do bad, ok = code_err("bad_args", "text is not valid UTF-8"), false
		}
		if ok {
			op.kind, doing = .Type, .Typing
			op.selector, op.text, op.clear, op.submit = strings.clone(c.selector), strings.clone(c.text), c.clear, c.submit
		}
	case core.Browser_Press:
		if bad, ok = sel_ok(c.selector, false); ok {
			if _, kerr := act_keys_parse(c.keys); kerr != "" do bad, ok = code_err("bad_keys", kerr), false
		}
		if ok {
			op.kind, doing = .Press, .Pressing
			op.selector, op.keys = strings.clone(c.selector), strings.clone(c.keys)
		}
	case core.Browser_Select:
		if bad, ok = sel_ok(c.selector, true); ok {
			if c.has_label == c.has_value do bad, ok = code_err("bad_args", "label or value is needed (one of them)"), false
		}
		if ok {
			op.kind, doing = .Select, .Choosing
			op.selector, op.label, op.value, op.has_label = strings.clone(c.selector), strings.clone(c.label), strings.clone(c.value), c.has_label
		}
	case core.Browser_Upload:
		if fcode, ferr := act_files_check(c.paths); ferr != "" do bad, ok = code_err(fcode, ferr), false
		else do bad, ok = sel_ok(c.selector, true)
		if ok {
			op.kind, doing = .Upload, .Uploading
			op.selector = strings.clone(c.selector)
			// each file by its real path (folder links resolved): the bar shows it, the page gets it
			for p in c.paths {
				real, rok := act_real_path(p)
				append(&op.paths, strings.clone(rok ? real : p))
			}
			who := agent_who(caller.kind, caller.claude)
			if caller.kind == .Panel {
				if s := core.caller_session(caller); s != nil do who = fmt.tprintf("%s in “%s”", who, core.open_session_title(s))
			}
			op.who_text = strings.clone(who)
		}
	case:
		ok = false
		bad = core.fail("not a browser action")
	}
	if !ok {
		act_free(op)
		return bad, false
	}
	// an agent's input is never the user's gesture: one the user just made is not left for it
	// (a download its click starts asks first: browser_polish.odin's download_take)
	page_extra(tab_id).input_at = {}
	append(&act_ops, op)
	agent_touch(tab_id, caller, doing)
	app.redraw = true
	return {ok = true, pending = true}, true
}

// ---- every frame (main.odin, after browser_agent_tick) ----

browser_act_tick :: proc() -> bool {
	// the lingering dot and sidebar line go when their time is up
	faded := false
	if len(act_linger) > 0 {
		gone := make([dynamic]u64, context.temp_allocator)
		for id, at in act_linger do if time.tick_since(at) >= ACT_LINGER do append(&gone, id)
		for id in gone do delete_key(&act_linger, id)
		faded = len(gone) > 0
	}
	if len(act_ops) == 0 do return act_marks_tick() || faded
	now := time.tick_now()
	redraw := false
	seen := make(map[u64]bool, context.temp_allocator)
	for i := 0; i < len(act_ops); {
		op := act_ops[i]
		if seen[op.tab_id] {
			i += 1
			continue // queued behind the tab's running action
		}
		seen[op.tab_id] = true
		if !op.active {
			op.active = true
			op.started = now
		
		}
		done, r := act_step(op, now)
		if done {
			act_end(op, r, r.ok)
			redraw = true
			continue // the list changed: the next one is at i
		}
		if op.msg_id == 0 && op.outstanding == 0 do redraw = true // waiting for the page, its world or a time
		i += 1
	}
	return act_marks_tick() || redraw || faded
}

@(private = "file")
act_marks_tick :: proc() -> bool {
	any := false
	for _, t in agent_tabs do if t.mark_at != {} {
		if time.tick_since(t.mark_at) > ACT_MARK_FOR do t.mark_at = {}
		else do any = true
	}
	return any
}

// The page's answer to our calls (browser_agent_devtools hands over ids it does not know).
browser_act_devtools :: proc(cef: c.int, msg_id: c.int, ok: c.int, data: [^]u8, n: c.size_t) -> bool {
	for op in act_ops {
		if op.cef != cef do continue
		if op.msg_id != 0 && op.msg_id == msg_id {
			op.msg_id = 0
			delete(op.reply)
			op.reply = strings.clone(string(data[:n]))
			if op.reply == "" do op.reply = strings.clone("{}")
			op.reply_ok = ok != 0
			app.redraw = true
			return true
		}
		if op.outstanding > 0 && msg_id >= op.first_id && msg_id <= op.last_id {
			op.outstanding -= 1
			if ok == 0 && op.send_err == "" do op.send_err = strings.clone(core.cut_utf8(string(data[:n]), 300))
			app.redraw = true
			return true
		}
	}
	return false
}

// Runtime.evaluate of browser_act.js in the isolated world (req: its argument, JSON).
@(private = "file")
act_eval :: proc(op: ^Act_Op, b: ^Browser, ctx: i64, req: string, by_value := true, track := true) {
	p := strings.builder_make(context.temp_allocator)
	strings.write_string(&p, `{"expression":`)
	core.json_quote(&p, strings.concatenate({"(", BROWSER_ACT_JS, ")(", req, ")"}, context.temp_allocator))
	fmt.sbprintf(&p, `,"contextId":%d,"returnByValue":%v,"silent":true}}`, ctx, by_value)
	id := cdp_send(agent_tab(op.tab_id), b.cef, "Runtime.evaluate", strings.to_string(p))
	if !track do return
	op.cef = b.cef
	op.msg_id = id
}

// The clipboard's change count when the action's input first goes (act_send; never the upload
// bar's wait).
act_clip_note_input :: proc(op: ^Act_Op) {
	if op.clip_armed || win_os.clipboard_count == nil do return
	op.clip0 = win_os.clipboard_count()
	op.clip_armed = true
}

// The clipboard changed since the action's input went.
act_clip_changed :: proc(op: ^Act_Op) -> bool {
	return op.clip_armed && win_os.clipboard_count != nil && win_os.clipboard_count() != op.clip0
}

// The input events of one step, sent at once (CDP runs them in order); their answers are counted.
@(private = "file")
act_send :: proc(op: ^Act_Op, b: ^Browser, calls: []string) -> bool {
	act_clip_note_input(op)
	t := agent_tab(op.tab_id)
	op.cef = b.cef
	op.first_id, op.last_id, op.outstanding = 0, 0, 0
	for call in calls {
		sp := strings.index_byte(call, ' ')
		id := cdp_send(t, b.cef, call[:sp], call[sp + 1:])
		if id == 0 do return false
		if op.first_id == 0 do op.first_id = id
		op.last_id = id
		op.outstanding += 1
	}
	return true
}

@(private = "file")
mouse :: proc(calls: ^[dynamic]string, kind: string, x, y: f64, button: core.Act_Button, clicks: int, mods: int, pressed: bool) {
	names := [core.Act_Button]string{.Left = "left", .Right = "right", .Middle = "middle"}
	masks := [core.Act_Button]int{.Left = 1, .Right = 2, .Middle = 4}
	btn := kind == "mouseMoved" ? "none" : names[button]
	mask := pressed ? masks[button] : 0
	append(calls, fmt.tprintf(`Input.dispatchMouseEvent {{"type":"%s","x":%.2f,"y":%.2f,"button":"%s","buttons":%d,"clickCount":%d,"modifiers":%d}}`, kind, x, y, btn, mask, clicks, mods))
}

@(private = "file")
key_calls :: proc(calls: ^[dynamic]string, k: Act_Key) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"type":"%s","modifiers":%d,"key":`, k.text != "" ? "keyDown" : "rawKeyDown", k.mods)
	core.json_quote(&b, k.key)
	strings.write_string(&b, `,"code":`)
	core.json_quote(&b, k.code)
	fmt.sbprintf(&b, `,"windowsVirtualKeyCode":%d`, k.vk)
	if k.text != "" {
		strings.write_string(&b, `,"text":`)
		core.json_quote(&b, k.text)
		strings.write_string(&b, `,"unmodifiedText":`)
		core.json_quote(&b, k.text)
	}
	if k.command != "" do fmt.sbprintf(&b, `,"commands":["%s"]`, k.command)
	strings.write_byte(&b, '}')
	append(calls, strings.concatenate({"Input.dispatchKeyEvent ", strings.to_string(b)}, context.temp_allocator))
	up := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&up, `{{"type":"keyUp","modifiers":%d,"key":`, k.mods)
	core.json_quote(&up, k.key)
	strings.write_string(&up, `,"code":`)
	core.json_quote(&up, k.code)
	fmt.sbprintf(&up, `,"windowsVirtualKeyCode":%d}}`, k.vk)
	append(calls, strings.concatenate({"Input.dispatchKeyEvent ", strings.to_string(up)}, context.temp_allocator))
}

// The keys' kinds (browser_press): navigation keys go anywhere; keys that produce text (a
// printable key without Cmd or Ctrl) only to a plain text field ("text" from browser_act.js's
// check); the rest (Backspace, Delete, shortcuts) anywhere but a sensitive field, a frame or
// something that cannot be checked.
Act_Key_Kind :: enum u8 {
	Nav,
	Text,
	Other,
}

act_key_kind :: proc(k: Act_Key) -> Act_Key_Kind {
	switch k.key {
	case "Tab", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight", "Enter", "Escape", "PageUp", "PageDown", "Home", "End":
		return .Nav
	}
	if k.text != "" && k.mods & (ACT_MOD_META | ACT_MOD_CONTROL) == 0 do return .Text
	return .Other
}

// Why the focused element (browser_act.js check's kind) does not take this input, or "".
act_refusal :: proc(kind: string, plain: bool, want: Act_Key_Kind) -> (code, msg: string) {
	if want == .Nav do return "", ""
	switch kind {
	case "frame":
		return "frame_focused", "focus is inside an embedded frame, which Deckhand cannot check for password or card fields: nothing was sent there. Ask the user to press Take over and type there themselves"
	case "sensitive":
		return "sensitive_field", ACT_SENSITIVE
	case "opaque":
		return "not_a_field", "focus is on an element Deckhand cannot look inside (a custom element with a closed shadow root, or an unknown one): agents only type into plain text fields"
	case "text":
		return "", ""
	}
	if want == .Text do return "not_a_field", kind == "none" ? "nothing that takes text has focus (the page itself, a button or a link): pass selector (a text field) or click one first" : "the focused element is not a plain text field (text, search, email, url, tel or number input, a textarea, or editable content)"
	// other keys (Backspace, Delete, shortcuts): a field, the page itself, or an element focusable
	// by nature (a button, a link); not an element Deckhand cannot classify (a custom widget)
	if kind == "none" && !plain do return "not_a_field", "focus is on an element Deckhand cannot classify (not a field, the page itself, a button or a link): keys like Backspace or shortcuts are not sent there; click a field or the page first"
	return "", ""
}

// One step of an action: done, with its answer.
@(private = "file")
act_step :: proc(op: ^Act_Op, now: time.Tick) -> (done: bool, r: core.Result) {
	_, tab, _ := find_tab(op.tab_id)
	b := browser_of(op.tab_id)
	if tab == nil || b == nil do return true, code_err("tab_gone", "the tab closed")
	bt, _ := tab.kind.(core.Browser_Tab)
	t := agent_tab(op.tab_id)
	late := time.tick_diff(op.deadline, now) > 0
	// a file chooser opened under the action: cancelled (agents upload with browser_upload)
	if op.file_dialog do return true, code_err("use_browser_upload", "the click opened the system's file chooser, which agents never get (it was cancelled): use browser_upload with the file input's selector")
	// never started: its time (from acceptance) ran out in the queue or waiting for the page
	if op.stage == .Page && late && !(b.cef == 0 && b.waiting) do return true, code_err("timeout", "the action waited too long (queued behind others, or the page not ready): nothing was sent")
	// the upload bar: the user's answer (browser_upload_answer), the page leaving, or the timeout
	if op.stage == .Bar {
		if t.navigated_at != {} && time.tick_diff(op.bar_at, t.navigated_at) > 0 || bt.url != op.url0 && op.url0 != "" {
			return true, code_err("page_changed", "the page navigated while the upload waited for the user: nothing was sent")
		}
		if late do return true, code_err("waiting_for_user", fmt.tprintf("the user did not answer the upload bar in %d s: nothing was sent (ask the user, then try again)", int(time.duration_seconds(ACT_UPLOAD_WAIT))))
		return false, {}
	}
	if !act_page_allowed(bt.url) do return true, code_err("page_not_allowed", "the page is not one agents act on (file:, chrome:, devtools: and other browser pages are the user's)")
	p := page_extras[op.tab_id]
	// the page itself: an unloaded tab loads into a free slot (never another tab's)
	if b.cef == 0 {
		if b.lazy {
			b.lazy = false
			app.redraw = true
		}
		if b.message != "" && !b.waiting do return true, code_err("no_page", fmt.tprintf("the page is not open: %s (browser_navigate opens it again)", b.message))
		if late do return true, b.waiting ? code_err("no_slot", "no page slot is free: too many open pages (the user's tabs keep theirs); try later") : code_err("timeout", "the page did not open in time")
		return false, {}
	}
	a := annot_of(op.tab_id)
	ctx := a != nil && a.cef == b.cef ? a.ctx : 0
	// a dialog on the page: the page waits for the user (and its input with it)
	if p != nil && p.dialog {
		if op.stage == .Page || op.stage == .Locate do return true, code_err("waiting_for_user", "a dialog on the page waits for the user's answer")
		return true, act_result(op, b, bt, t, p)
	}
	// an answer
	value: string
	have := false
	if op.reply != "" {
		reply, rok := op.reply, op.reply_ok
		defer {
			delete(op.reply)
			op.reply = ""
		}
		v, verr := eval_reply(reply, rok, op.stage == .File_El)
		if verr != "" {
			if op.stage == .Check && act_page_changed(op, bt, t, p, ctx) do return true, act_changed(op)
			return true, code_err("page_error", fmt.tprintf("the page did not answer: %s (it may be navigating; browser_wait, then try again)", verr))
		}
		value, have = v, true
	}
	if op.outstanding > 0 {
		if late do return true, code_err("timeout", "the page did not take the input in time")
		return false, {}
	}
	if op.send_err != "" do return true, code_err("page_error", fmt.tprintf("the input was refused: %s", op.send_err))
	if op.msg_id != 0 {
		if late do return true, code_err("timeout", "the page did not answer in time")
		return false, {}
	}
	if late do return true, code_err("timeout", ctx == 0 ? "the page is not ready (no document yet)" : "the action did not finish in time")
	obj: json.Object
	if have && op.stage != .File_El || have && op.stage == .File_El && strings.has_prefix(value, "{") {
		jv, perr := jg.parse_string(value, .JSON, true, context.temp_allocator)
		o, is := jv.(json.Object)
		if perr != nil || !is do return true, code_err("page_error", "the page's answer was not readable")
		if e, has := o["error"].(json.String); has {
			code, _ := o["code"].(json.String)
			return true, code_err(code != "" ? code : "bad_args", e)
		}
		obj = o
	}
	switch op.stage {
	case .Page:
		if ctx == 0 do return false, {}
		t.wake = true // a hidden tab paints and takes input while the action runs
		dh_cef_invalidate(b.cef)
		op.nav0 = t.navigated_at
		op.navs0 = p != nil ? p.nav_started : {}
		op.ctx0 = ctx
		own(&op.url0, bt.url)
		op.dl0 = p != nil ? p.ask_id : 0
		if into_view(op) {
			// where the page was, before the target is scrolled into view
			op.stage = .Scroll_Before
			act_eval(op, b, ctx, `{"op":"scroll","x":0,"y":0}`)
			return false, {}
		}
		op.stage = .Locate
		act_eval(op, b, ctx, locate_req(op))
		return false, {}
	case .Locate:
		hit, _ := json.marshal(obj["hit"], allocator = context.temp_allocator)
		own(&op.hit, string(hit))
		op.px, _ = num(obj["x"])
		op.py, _ = num(obj["y"])
		name, _ := obj["hit"].(json.Object)["name"].(json.String)
		role, _ := obj["hit"].(json.Object)["role"].(json.String)
		own(&t.act_target, name != "" ? name : role)
		app.redraw = true
		// the page found the target; still the same page right before the input (a select chose
		// in that same call)
		if op.kind != .Select && act_page_changed(op, bt, t, p, ctx) do return true, act_changed(op)
		if dis, _ := obj["disabled"].(json.Boolean); dis && (op.kind == .Click || op.kind == .Type || op.kind == .Upload) {
			return true, code_err("disabled", fmt.tprintf("the target is disabled: %s", string(hit)))
		}
		if cov, has := obj["covered"]; has && (op.kind == .Click || op.kind == .Hover) {
			what, _ := json.marshal(cov, allocator = context.temp_allocator)
			return true, code_err("covered", fmt.tprintf("another element is on top of the target at its centre: %s (close it, scroll, or click it at x,y)", string(what)))
		}
		if sens, _ := obj["sensitive"].(json.Boolean); sens && op.kind == .Type do return true, code_err("sensitive_field", ACT_SENSITIVE)
		switch op.kind {
		case .Select:
			own(&op.scroll0, value) // its answer: hit and chosen
			op.stage = .Settle
			op.settle_at = time.tick_add(now, ACT_SETTLE)
		case .Upload:
			multiple, _ := obj["multiple"].(json.Boolean)
			if len(op.paths) > 1 && !multiple do return true, code_err("bad_args", "this file input takes one file")
			jo, _ := obj["origin"].(json.String)
			own(&op.js_origin, jo)
			own(&op.origin, url_origin(bt.url))
			op.stage = .Bar
			op.bar_at = now
			op.deadline = time.tick_add(now, ACT_UPLOAD_WAIT)
			t.wake = false
			agent_unwake(op.tab_id)
			fmt.printfln("[browser] tab %d: %s asks to upload %d file(s) to %s", op.tab_id, op.who_text, len(op.paths), op.origin)
			app.redraw = true
		case .Scroll:
			if into_view(op) {
				op.stage = .Settle // scrolled into view by the target call
				op.settle_at = now
			} else {
				op.stage = .Scroll_Before
				act_eval(op, b, ctx, fmt.tprintf(`{{"op":"scroll","x":%.2f,"y":%.2f}}`, op.px, op.py))
			}
		case .Type, .Press:
			act_check(op, b, ctx)
		case .Click, .Hover:
			calls := make([dynamic]string, context.temp_allocator)
			mouse(&calls, "mouseMoved", op.px, op.py, op.button, 0, op.mods, false)
			if op.kind == .Click {
				mouse(&calls, "mousePressed", op.px, op.py, op.button, 1, op.mods, true)
				mouse(&calls, "mouseReleased", op.px, op.py, op.button, 1, op.mods, false)
				if op.double {
					mouse(&calls, "mousePressed", op.px, op.py, op.button, 2, op.mods, true)
					mouse(&calls, "mouseReleased", op.px, op.py, op.button, 2, op.mods, false)
				}
				t.mark_at, t.mark_x, t.mark_y = now, f32(op.px), f32(op.py)
			}
			if !act_send(op, b, calls[:]) do return true, code_err("page_error", "the input could not be sent")
			op.stage = .Send
		}
		return false, {}
	case .Scroll_Before:
		own(&op.scroll0, value)
		if into_view(op) {
			op.stage = .Locate // now find it (and scroll it into view)
			act_eval(op, b, ctx, locate_req(op))
			return false, {}
		}
		if act_page_changed(op, bt, t, p, ctx) do return true, act_changed(op)
		calls := make([dynamic]string, context.temp_allocator)
		mouse(&calls, "mouseMoved", op.px, op.py, .Left, 0, 0, false)
		append(&calls, fmt.tprintf(`Input.dispatchMouseEvent {{"type":"mouseWheel","x":%.2f,"y":%.2f,"deltaX":%.2f,"deltaY":%.2f,"modifiers":0}}`, op.px, op.py, op.dx, op.dy))
		if !act_send(op, b, calls[:]) do return true, code_err("page_error", "the input could not be sent")
		op.stage = .Send
		return false, {}
	case .Check:
		// right before each input: the same page, and the focused element takes it
		if act_page_changed(op, bt, t, p, ctx) do return true, act_changed(op)
		kind, _ := obj["kind"].(json.String)
		plain, _ := obj["plain"].(json.Boolean)
		calls := make([dynamic]string, context.temp_allocator)
		if op.kind == .Type {
			if !op.inserted && (op.text != "" || op.clear) {
				// the text: one check, then all of it at once (Input.insertText is atomic)
				if code, msg := act_refusal(string(kind), plain, .Text); code != "" do return true, code_err(code, msg)
				ml, _ := obj["multiline"].(json.Boolean)
				if !ml && strings.contains_any(op.text, "\r\n") do return true, code_err("bad_args", "the text has a line break, and this field is a single line: leave it out (submit presses Enter)")
				if op.text != "" {
					text, _ := strings.replace_all(op.text, "\r\n", "\n", context.temp_allocator)
					text, _ = strings.replace_all(text, "\r", "\n", context.temp_allocator)
					b2 := strings.builder_make(context.temp_allocator)
					strings.write_string(&b2, `{"text":`)
					core.json_quote(&b2, text)
					strings.write_byte(&b2, '}')
					append(&calls, strings.concatenate({"Input.insertText ", strings.to_string(b2)}, context.temp_allocator))
				} else {
					k, _ := act_key_named("Backspace", 0) // clear with no text: the selection goes
					key_calls(&calls, k)
				}
				op.pos = len(op.text)
				op.inserted = true
			} else if op.submit && !op.submitted {
				// submit: one Enter after a fresh check (a navigation key: it goes anywhere)
				op.submitted = true
				k, _ := act_key_named("Enter", 0)
				key_calls(&calls, k)
			}
		} else {
			keys, _ := act_keys_parse(op.keys)
			if op.sent_keys < len(keys) {
				// one chord a check
				k := keys[op.sent_keys]
				if code, msg := act_refusal(string(kind), plain, act_key_kind(k)); code != "" {
					if op.sent_keys > 0 do msg = fmt.tprintf("%s (%d of %d chords were pressed before)", msg, op.sent_keys, len(keys))
					return true, code_err(code, msg)
				}
				key_calls(&calls, k)
				op.sent_keys += 1
			}
		}
		if len(calls) == 0 {
			op.stage = .Settle
			op.settle_at = time.tick_add(now, ACT_SETTLE)
			return false, {}
		}
		if !act_send(op, b, calls[:]) do return true, code_err("page_error", "the input could not be sent")
		op.stage = .Send
		return false, {}
	case .Send:
		// the input went (and was taken): the next key waits a moment and is checked again; the
		// rest settles
		if op.kind == .Type && op.submit && !op.submitted {
			op.stage = .Gap
			op.settle_at = now
			return false, {}
		}
		if op.kind == .Press {
			keys, _ := act_keys_parse(op.keys)
			if op.sent_keys < len(keys) {
				op.stage = .Gap
				op.settle_at = time.tick_add(now, keys[op.sent_keys - 1].key == "Enter" ? ACT_ENTER_GAP : ACT_KEY_GAP)
				return false, {}
			}
		}
		op.stage = .Settle
		op.settle_at = time.tick_add(now, ACT_SETTLE)
		return false, {}
	case .Gap:
		if time.tick_diff(op.settle_at, now) < 0 do return false, {}
		act_check(op, b, ctx)
		return false, {}
	case .Settle:
		if time.tick_diff(op.settle_at, now) < 0 do return false, {}
		// a navigation it started: until the new page loaded, at most ACT_NAV_WAIT
		navigated := time.tick_diff(op.nav0, t.navigated_at) > 0 || bt.url != op.url0
		if (navigated || bt.loading) && bt.loading && time.tick_diff(op.settle_at, now) < ACT_NAV_WAIT do return false, {}
		if op.kind == .Scroll && !navigated && ctx != 0 {
			op.stage = .Scroll_After
			act_eval(op, b, ctx, fmt.tprintf(`{{"op":"scroll","x":%.2f,"y":%.2f}}`, op.px, op.py))
			return false, {}
		}
		return true, act_result(op, b, bt, t, p)
	case .Scroll_After:
		return true, act_result(op, b, bt, t, p, value)
	case .File_El:
		// the file input as an object of our world, then its files (nothing went before Allow);
		// the page still on the origin the bar named, the element still a file input
		if !have {
			if ctx == 0 do return false, {}
			if url_origin(bt.url) != op.origin do return true, code_err("page_changed", "the page moved to another site after Allow: nothing was sent")
			t.wake = true
			dh_cef_invalidate(b.cef)
			req := strings.builder_make(context.temp_allocator)
			strings.write_string(&req, `{"op":"file_el","sel":`)
			core.json_quote(&req, op.selector)
			strings.write_string(&req, `,"origin":`)
			core.json_quote(&req, op.js_origin)
			strings.write_byte(&req, '}')
			act_eval(op, b, ctx, strings.to_string(req), by_value = false)
			return false, {}
		}
		if value == "" do return true, code_err("not_found", "the file input is gone from the page: nothing was sent")
		if url_origin(bt.url) != op.origin do return true, code_err("page_changed", "the page moved to another site after Allow: nothing was sent")
		own(&op.object_id, value)
		pb := strings.builder_make(context.temp_allocator)
		strings.write_string(&pb, `{"files":[`)
		for f, i in op.paths {
			if i > 0 do strings.write_byte(&pb, ',')
			core.json_quote(&pb, f)
		}
		strings.write_string(&pb, `],"objectId":`)
		core.json_quote(&pb, op.object_id)
		strings.write_byte(&pb, '}')
		calls := []string{strings.concatenate({"DOM.setFileInputFiles ", strings.to_string(pb)}, context.temp_allocator)}
		if !act_send(op, b, calls) do return true, code_err("page_error", "the files could not be sent")
		op.stage = .Send
		return false, {}
	case .Set_Files, .Bar:
	}
	return false, {}

	num :: proc(v: json.Value) -> (f64, bool) {
		#partial switch x in v {
		case json.Integer: return f64(x), true
		case json.Float:   return f64(x), true
		}
		return 0, false
	}
	// Runtime.evaluate's result: the string value (by value), or the object's id (object: true;
	// a string value then is browser_act.js's error)
	eval_reply :: proc(reply: string, ok: bool, object: bool) -> (string, string) {
		v, err := jg.parse_string(reply, .JSON, true, context.temp_allocator)
		if err != nil do return "", "unreadable reply"
		o, _ := v.(json.Object)
		if !ok {
			msg, _ := o["message"].(json.String)
			return "", msg != "" ? msg : "error"
		}
		if ex, has := o["exceptionDetails"].(json.Object); has {
			text, _ := ex["text"].(json.String)
			return "", text != "" ? text : "exception"
		}
		res, _ := o["result"].(json.Object)
		if object {
			if id, has := res["objectId"].(json.String); has do return string(id), ""
			if s, is := res["value"].(json.String); is do return string(s), ""
			return "", ""
		}
		s, is := res["value"].(json.String)
		if !is do return "", "no value"
		return s, ""
	}
}

// The focused element now (browser_act.js check), right before the next input; the type's first
// check selects the field's content when it clears.
@(private = "file")
act_check :: proc(op: ^Act_Op, b: ^Browser, ctx: i64) {
	op.stage = .Check
	sel := op.kind == .Type && op.clear && !op.inserted
	act_eval(op, b, ctx, sel ? `{"op":"check","select":true}` : `{"op":"check"}`)
}

@(private = "file")
act_keys_count :: proc(keys: string) -> int {
	k, _ := act_keys_parse(keys)
	return len(k)
}

// The page is not the one the action started on: a main-frame navigation started or committed,
// the address's origin changed, or our world's context is another (a new document). The address
// changing within the document (history.replaceState / pushState) is not a new page.
@(private = "file")
act_page_changed :: proc(op: ^Act_Op, bt: core.Browser_Tab, t: ^Agent_Tab, p: ^Page_Extra, ctx: i64) -> bool {
	if time.tick_diff(op.nav0, t.navigated_at) > 0 do return true
	if p != nil && time.tick_diff(op.navs0, p.nav_started) > 0 do return true
	// the address may change within the document (an app's replaceState as you type): only its
	// origin counts; a new document shows as a navigation or a new context
	if url_origin(bt.url) != url_origin(op.url0) do return true
	if op.ctx0 != 0 && ctx != op.ctx0 do return true
	return false
}

@(private = "file")
act_changed :: proc(op: ^Act_Op) -> core.Result {
	sent := ""
	switch op.kind {
	case .Type:
		sent = op.inserted ? " after the text was inserted" : " before anything was typed"
		if op.submitted do sent = " after the text and Enter"
	case .Press:
		sent = fmt.tprintf(" after %d of %d chords", op.sent_keys, act_keys_count(op.keys))
	case .Click, .Hover, .Scroll, .Select, .Upload:
		sent = ": nothing was sent"
	}
	return code_err("page_changed", fmt.tprintf("the page navigated or changed during the action%s; nothing more was sent (read the page again before acting)", sent))
}

// The first call of an action: find its target (browser_act.js target, select or check).
@(private = "file")
locate_req :: proc(op: ^Act_Op) -> string {
	req := strings.builder_make(context.temp_allocator)
	switch op.kind {
	case .Click, .Hover:
		strings.write_string(&req, `{"op":"target","need":"any"`)
		act_req_target(&req, op)
		strings.write_byte(&req, '}')
	case .Scroll:
		strings.write_string(&req, `{"op":"target","need":"any"`)
		if op.selector == "" && !op.has_xy do strings.write_string(&req, `,"center":true`)
		if op.selector != "" do fmt.sbprintf(&req, `,"scroll":%v`, op.dx == 0 && op.dy == 0)
		act_req_target(&req, op)
		strings.write_byte(&req, '}')
	case .Type, .Press:
		if op.selector == "" do strings.write_string(&req, `{"op":"check"}`)
		else {
			fmt.sbprintf(&req, `{{"op":"target","focus":true,"need":"%s"`, op.kind == .Type ? "field" : "any")
			act_req_target(&req, op)
			strings.write_byte(&req, '}')
		}
	case .Select:
		strings.write_string(&req, `{"op":"select","sel":`)
		core.json_quote(&req, op.selector)
		strings.write_string(&req, op.has_label ? `,"label":` : `,"value":`)
		core.json_quote(&req, op.has_label ? op.label : op.value)
		strings.write_byte(&req, '}')
	case .Upload:
		strings.write_string(&req, `{"op":"target","need":"file","scroll":false,"sel":`)
		core.json_quote(&req, op.selector)
		strings.write_byte(&req, '}')
	}
	return strings.to_string(req)
}

// A scroll that brings its target into view (no wheel): the offsets before come first.
@(private = "file")
into_view :: proc(op: ^Act_Op) -> bool {
	return op.kind == .Scroll && op.selector != "" && op.dx == 0 && op.dy == 0
}

@(private = "file")
act_req_target :: proc(b: ^strings.Builder, op: ^Act_Op) {
	if op.selector != "" {
		strings.write_string(b, `,"sel":`)
		core.json_quote(b, op.selector)
	} else if op.has_xy do fmt.sbprintf(b, `,"x":%v,"y":%v`, op.x, op.y)
}

// The finished action's data (page data: the requester's only).
@(private = "file")
act_result :: proc(op: ^Act_Op, b: ^Browser, bt: core.Browser_Tab, t: ^Agent_Tab, p: ^Page_Extra, after := "") -> core.Result {
	w := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&w, `{{"action":"%s"`, ACT_KIND_NAMES[op.kind])
	if op.kind == .Select {
		// browser_act.js's answer: {hit, chosen}
		v, err := jg.parse_string(op.scroll0, .JSON, true, context.temp_allocator)
		o, _ := v.(json.Object)
		if err == nil {
			h, _ := json.marshal(o["hit"], allocator = context.temp_allocator)
			ch, _ := json.marshal(o["chosen"], allocator = context.temp_allocator)
			fmt.sbprintf(&w, `,"hit":%s,"chosen":%s`, string(h), string(ch))
		}
	} else if op.hit != "" do fmt.sbprintf(&w, `,"hit":%s`, op.hit)
	switch op.kind {
	case .Click, .Hover:
		fmt.sbprintf(&w, `,"x":%d,"y":%d`, int(op.px), int(op.py))
	case .Type:
		fmt.sbprintf(&w, `,"chars":%d,"submitted":%v`, utf8.rune_count(op.text[:op.pos]), op.submitted)
	case .Press:
		fmt.sbprintf(&w, `,"keys":%d`, op.sent_keys)
	case .Upload:
		strings.write_string(&w, `,"files":[`)
		for f, i in op.paths {
			if i > 0 do strings.write_byte(&w, ',')
			core.json_quote(&w, filepath.base(f))
		}
		strings.write_byte(&w, ']')
	case .Scroll:
		v0, e0 := jg.parse_string(op.scroll0, .JSON, true, context.temp_allocator)
		v1, e1 := jg.parse_string(after, .JSON, true, context.temp_allocator)
		o0, _ := v0.(json.Object)
		o1, _ := v1.(json.Object)
		if e0 == nil && e1 == nil && after != "" {
			n :: proc(v: json.Value) -> int {
				#partial switch x in v {
				case json.Integer: return int(x)
				case json.Float:   return int(x)
				}
				return 0
			}
			moved := n(o0["x"]) != n(o1["x"]) || n(o0["y"]) != n(o1["y"]) || n(o0["inner"]) != n(o1["inner"])
			fmt.sbprintf(&w, `,"scroll_x":%d,"scroll_y":%d,"moved":%v`, n(o1["x"]), n(o1["y"]), moved)
		}
	case .Select:
	}
	navigated := time.tick_diff(op.nav0, t.navigated_at) > 0 || bt.url != op.url0
	strings.write_string(&w, `,"url":`)
	core.json_quote(&w, agent_url_masked(bt.url))
	fmt.sbprintf(&w, `,"navigated":%v,"loading":%v`, navigated, bt.loading)
	if p != nil && p.ask_id != 0 && p.ask_id != op.dl0 do strings.write_string(&w, `,"download":"waiting_for_user"`)
	if p != nil && p.dialog do strings.write_string(&w, `,"dialog":"waiting_for_user"`)
	if op.popup != 0 do fmt.sbprintf(&w, `,"popup":%d`, op.popup)
	if act_clip_changed(op) do strings.write_string(&w, `,"clipboard_changed":true`)
	strings.write_byte(&w, '}')
	return {ok = true, data = strings.to_string(w)}
}

// ---- State and drawing ----

// `,"upload_ask":{files, who}` while the tab's upload bar asks (base names only, never paths).
browser_act_tab_facts :: proc(f: ^core.Browser_Facts, tab_id: u64) {
	op := act_upload_asking(tab_id)
	if op == nil do return
	files := make([]string, len(op.paths), context.temp_allocator)
	for p, i in op.paths do files[i] = filepath.base(p)
	f.upload_ask = core.Browser_Upload_Fact{files = files, who = op.who_text}
}

// The upload bar's words (browser_polish.odin draws it): who asks and the files' full paths.
browser_act_upload_words :: proc(tab_id: u64) -> (who, names: string, ok: bool) {
	op := act_upload_asking(tab_id)
	if op == nil do return "", "", false
	list := make([dynamic]string, context.temp_allocator)
	for f in op.paths do append(&list, act_path_shown(f)) // full paths (~ for home), each on one line
	return op.who_text, strings.join(list[:], ", ", context.temp_allocator), true
}

// The upload bar's signature part (browser_polish.odin's page_bars_sig: its click guard).
browser_act_bar_sig :: proc(tab_id: u64) -> string {
	op := act_upload_asking(tab_id)
	return op == nil ? "" : fmt.tprintf("upload %d;", op.request_id)
}

// A brief ring where an agent clicked (browser.odin's browser_draw, over the page).
browser_act_draw :: proc(tab_id: u64, x, y, w, h: f32) {
	t := agent_tab_of(tab_id)
	if t == nil || t.mark_at == {} do return
	zoom: f32 = 1
	if a := annot_of(tab_id); a != nil && a.zoom > 0 do zoom = a.zoom
	th := theme()
	k := zoom * app.dpi
	cx, cy := x + t.mark_x * k, y + t.mark_y * k
	if cx < x || cy < y || cx > x + w || cy > y + h do return
	r := 12 * app.dpi
	ring := max(1, 2 * app.dpi)
	draw_rect(cx - r, cy - r, 2 * r, ring, th.accent)
	draw_rect(cx - r, cy + r - ring, 2 * r, ring, th.accent)
	draw_rect(cx - r, cy - r, ring, 2 * r, th.accent)
	draw_rect(cx + r - ring, cy - r, ring, 2 * r, th.accent)
	draw_rect(cx - 2 * app.dpi, cy - 2 * app.dpi, 4 * app.dpi, 4 * app.dpi, th.accent)
}

// ---- test mode (autotest.odin) ----
//
//   act_assert mark yes|no        a click ring shows on the tab on screen
//   act_assert ops N              actions running or queued (every tab)
//   act_assert control user|agent  who has the tab on screen (Take over)
//   act_assert clipboard TEXT     the system clipboard's text
//   act_clipboard set TEXT        put TEXT on the system clipboard

act_script :: proc(cmd: string, args: []string, rest: string) -> (msg: string, ok: bool) {
	if cmd == "act_clipboard" {
		// the system clipboard's text (the scene's starting point)
		if len(args) < 2 || args[0] != "set" do return "act_clipboard set TEXT", false
		sapp.set_clipboard_string(strings.clone_to_cstring(strings.trim_space(rest[strings.index(rest, "set") + 3:]), context.temp_allocator))
		return "", true
	}
	if cmd != "act_assert" || len(args) < 2 do return "act_assert mark|ops|control|clipboard …", false
	b := tab_browser()
	t := b != nil ? agent_tab_of(b.tab_id) : nil
	got: string
	switch args[0] {
	case "mark":    got = t != nil && t.mark_at != {} ? "yes" : "no"
	case "ops":     got = fmt.tprint(len(act_ops))
	case "control": got = t != nil && t.user_control ? "user" : "agent"
	case "clipboard":
		got = string(sapp.get_clipboard_string())
		want := strings.trim_space(rest[strings.index(rest, "clipboard") + 9:])
		if got != want do return fmt.tprintf("ASSERT FAILED act_assert clipboard: got %q, want %q", got, want), false
		fmt.printfln("[act] assert ok: clipboard = %q", got)
		return "", true
	case: return fmt.tprintf("act_assert: unknown %s", args[0]), false
	}
	if got != args[1] do return fmt.tprintf("ASSERT FAILED act_assert %s: got %q, want %q", args[0], got, args[1]), false
	fmt.printfln("[act] assert ok: %s = %s", args[0], got)
	return "", true
}

// The command plumbing (type names, copies, events' fields): browser_wire.odin.
