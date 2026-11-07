package main

// Browser tabs, step 3: tab polish (docs/BROWSER.md §6, "Step 3 results"). What CEF expects from
// its host besides painting, drawn and decided by pi-desk (the shim only translates:
// src/native/cef_polish.inc):
//
//  - the page's cursor and tooltips (the pointer over the page);
//  - a right-click menu drawn by pi-desk (Chromium's own is emptied): Back, Forward, Reload; Cut,
//    Copy, Paste, Select all; Open link in new tab (in this tab's session: a tab never leaves its
//    session, and neither do the tabs it opens), Copy link; Inspect;
//  - JS dialogs (alert, confirm, prompt, beforeunload) as a bar in the tab: OK / Cancel;
//  - find in page (⌘F, or Find in page in ⋯): a bar with the field, "N of M", ‹ › and ×;
//  - zoom (⌘+ ⌘− ⌘0 with a browser tab on screen; ⋯; the toolbar's "125%" resets it). Chromium
//    keeps zoom per host; State's `zoom` is the page's factor, and comment mode's CSS-to-tab
//    mapping takes it (browser_annotate.odin's Annot.zoom);
//  - downloads into ~/Downloads (test mode: the data dir's downloads/) under a safe name that never
//    overwrites a file (download_safe_name, download_reserve), with a bar: Open, Show in Finder;
//  - the blocked-popup bar (blocked_popup, step 2): Open (a new tab in the same session), ×;
//  - permission bars (notifications, location, camera, microphone): Allow / Block, once (nothing
//    is remembered per site yet);
//  - a crash bar when the page's renderer died: Reload;
//  - DevTools, Chromium's own, in a window of its own (in process: no remote debugging port; the
//    DevTools protocol domains it turns on are its own business, opened by the user only).
//
// Every action has a button (the bars, the ⋯ menu and the right-click menu) as well as a key or a
// palette entry. Its commands (browser_zoom, browser_find, …) are the user's only for now: none of
// them is offered to agents (that is steps 7 and 8, with their own permissions).
//
// DPI changes (moving the window between displays) were already followed by browser_tick
// (pd_cef_resize passes the scale: NotifyScreenInfoChanged + WasResized); the ring follows the
// new paint size.
//
// Runtime per tab (Page_Extra, keyed by tab id like the comment mode's Annot) holds what the page
// reported; State shows it (browser_polish_tab_json). Reports bump State through browser_report.

import "core:c"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "base:runtime"
import sapp "../vendor/sokol-odin/sokol/app"
import clay "../build/clay-odin"

// ---- the shim (src/native/cef_polish.inc) ----

Cef_Polish_Callbacks :: struct {
	cursor:        proc "c" (id: c.int, type: c.int),
	tooltip:       proc "c" (id: c.int, utf8: cstring),
	context_menu:  proc "c" (id: c.int, flags, edit: c.int, link: cstring),
	dialog:        proc "c" (id: c.int, kind: c.int, message, default_text, origin: cstring),
	find:          proc "c" (id: c.int, request, count, active, final_update: c.int),
	download_path: proc "c" (id: c.int, dl: u32, suggested, url: cstring, out: [^]u8, cap: c.int) -> c.int,
	download:      proc "c" (id: c.int, dl: u32, state: c.int, received, total: i64, path: cstring, quarantined: c.int),
	permission:    proc "c" (id: c.int, what: u32, origin: cstring),
	crashed:       proc "c" (id: c.int, status: c.int),
	navigated:     proc "c" (id: c.int), // a main-frame navigation starts
	file_dialog:   proc "c" (id: c.int) -> c.int, // a native file chooser opens: 1 = cancel it
}

when PI_DESK_CEF && ODIN_OS == .Darwin {
	foreign import pdcef_polish {
		"../build/pd_cef.a",
		"system:CoreServices.framework", // LaunchServices' quarantine keys (cef_polish.inc)
	}

	@(default_calling_convention = "c")
	foreign pdcef_polish {
		pd_cef_polish_callbacks_set :: proc(cbs: ^Cef_Polish_Callbacks) ---
		pd_cef_edit :: proc(id: c.int, op: c.int) ---
		pd_cef_dialog_answer :: proc(id: c.int, ok: c.int, text: cstring) -> c.int ---
		pd_cef_find :: proc(id: c.int, text: cstring, forward, next: c.int) ---
		pd_cef_find_stop :: proc(id: c.int) ---
		pd_cef_zoom_get :: proc(id: c.int) -> f64 ---
		pd_cef_zoom_set :: proc(id: c.int, level: f64) ---
		pd_cef_download_cancel :: proc(dl: u32) ---
		pd_cef_download_answer :: proc(id: c.int, dl: u32, path: cstring) -> c.int ---
		pd_cef_permission_answer :: proc(id: c.int, allow: c.int) -> c.int ---
		pd_cef_devtools_show :: proc(id: c.int, x, y: c.int) -> c.int ---
		pd_cef_devtools_open :: proc(id: c.int) -> c.int ---
		pd_cef_devtools_close :: proc(id: c.int) ---
		pd_cef_test_crash :: proc(id: c.int) ---
	}
} else {
	pd_cef_polish_callbacks_set :: proc(cbs: ^Cef_Polish_Callbacks) {}
	pd_cef_edit :: proc(id: c.int, op: c.int) {}
	pd_cef_dialog_answer :: proc(id: c.int, ok: c.int, text: cstring) -> c.int {return 0}
	pd_cef_find :: proc(id: c.int, text: cstring, forward, next: c.int) {}
	pd_cef_find_stop :: proc(id: c.int) {}
	pd_cef_zoom_get :: proc(id: c.int) -> f64 {return 0}
	pd_cef_zoom_set :: proc(id: c.int, level: f64) {}
	pd_cef_download_cancel :: proc(dl: u32) {}
	pd_cef_download_answer :: proc(id: c.int, dl: u32, path: cstring) -> c.int {return 0}
	pd_cef_permission_answer :: proc(id: c.int, allow: c.int) -> c.int {return 0}
	pd_cef_devtools_show :: proc(id: c.int, x, y: c.int) -> c.int {return 0}
	pd_cef_devtools_open :: proc(id: c.int) -> c.int {return 0}
	pd_cef_devtools_close :: proc(id: c.int) {}
	pd_cef_test_crash :: proc(id: c.int) {}
}

// cef_permission_request_types_t bits the bars name
PERM_CAMERA :: u32(1 << 2)
PERM_GEOLOCATION :: u32(1 << 8)
PERM_MIC :: u32(1 << 12)
PERM_NOTIFICATIONS :: u32(1 << 15)
// cef_context_menu_type_flags_t, cef_context_menu_edit_state_flags_t
CM_LINK :: c.int(1 << 2)
CM_SELECTION :: c.int(1 << 4)
CM_EDITABLE :: c.int(1 << 5)
CM_CAN_UNDO :: c.int(1 << 0)
CM_CAN_REDO :: c.int(1 << 1)
CM_CAN_CUT :: c.int(1 << 2)
CM_CAN_COPY :: c.int(1 << 3)
CM_CAN_PASTE :: c.int(1 << 4)
CM_CAN_SELECT_ALL :: c.int(1 << 6)

// ---- commands (the user's: who = .User) ----

Browser_Zoom_Step :: enum u8 {
	Reset,
	In,
	Out,
}
BROWSER_ZOOM_STEP_NAMES := [Browser_Zoom_Step]string {
	.Reset = "reset",
	.In    = "in",
	.Out   = "out",
}
Browser_Edit_Op :: enum u8 {
	Undo,
	Redo,
	Cut,
	Copy,
	Paste,
	Select_All,
}
BROWSER_EDIT_OP_NAMES := [Browser_Edit_Op]string {
	.Undo       = "undo",
	.Redo       = "redo",
	.Cut        = "cut",
	.Copy       = "copy",
	.Paste      = "paste",
	.Select_All = "select_all",
}
Browser_Download_Op :: enum u8 {
	Open,
	Reveal,
	Cancel,
	Dismiss,
	Allow, // a download the page started without the user's click: go ahead (download_ask)
	Block, // … or not
}
BROWSER_DOWNLOAD_OP_NAMES := [Browser_Download_Op]string {
	.Open    = "open",
	.Reveal  = "reveal",
	.Cancel  = "cancel",
	.Dismiss = "dismiss",
	.Allow   = "allow",
	.Block   = "block",
}

Browser_Zoom :: struct {
	tab_id: u64,
	step:   Browser_Zoom_Step,
}
Browser_Find :: struct {
	tab_id: u64,
	text:   string, // "" clears the matches (the bar stays)
	back:   bool, // the previous match
}
Browser_Find_Close :: struct {
	tab_id: u64,
}
Browser_Dialog :: struct {
	tab_id: u64,
	ok:     bool,
	text:   string, // a prompt's answer
}
Browser_Permission :: struct {
	tab_id: u64,
	allow:  bool,
}
Browser_Popup :: struct {
	tab_id: u64,
	open:   bool, // false: only the bar goes
}
Browser_Edit :: struct {
	tab_id: u64,
	op:     Browser_Edit_Op,
}
Browser_Devtools :: struct {
	tab_id: u64,
	x, y:   i32, // inspect the element at this page position (logical px); -1: just open
	close:  bool,
}
Browser_External :: struct {
	tab_id: u64,
}
Browser_Download :: struct {
	download_id: u64,
	op:          Browser_Download_Op,
}

// ---- runtime per tab ----

Page_Dialog_Kind :: enum u8 {
	Alert,
	Confirm,
	Prompt,
	Leave,
	Leave_Reload,
}
PAGE_DIALOG_NAMES := [Page_Dialog_Kind]string {
	.Alert        = "alert",
	.Confirm      = "confirm",
	.Prompt       = "prompt",
	.Leave        = "beforeunload",
	.Leave_Reload = "beforeunload",
}

Download_State :: enum u8 {
	Going,
	Done,
	Cancelled,
	Failed,
}
DOWNLOAD_STATE_NAMES := [Download_State]string {
	.Going     = "going",
	.Done      = "done",
	.Cancelled = "cancelled",
	.Failed    = "failed",
}

Page_Download :: struct {
	id:       u32, // CEF's
	tab_id:   u64, // the tab it was started in (its bar)
	name:     string, // owned: the file's name
	path:     string, // owned: where it goes
	url:      string, // owned
	state:    Download_State,
	received: i64,
	total:    i64, // -1 unknown
	dismissed: bool, // its bar was closed
	quarantined: bool, // marked as downloaded (com.apple.quarantine): Open needs it
}

Page_Extra :: struct {
	tab_id:        u64,
	cef:           c.int, // the browser what follows belongs to (another one: it goes)
	zoom_level:    f64, // Chromium's (factor 1.2^level)
	crashed:       bool,
	crash_status:  int,
	crash_painted: u64, // b.painted when it crashed: a new frame means a live page again
	dialog:        bool,
	dialog_kind:   Page_Dialog_Kind,
	dialog_msg:    string, // owned
	dialog_origin: string, // owned
	perm:          u32, // permission bits asked (0 = no bar)
	perm_origin:   string, // owned
	find_open:     bool,
	find_text:     string, // owned: what was searched
	find_matches:  int,
	find_active:   int,
	cursor:        sapp.Mouse_Cursor,
	tooltip:       string, // owned
	devtools:      bool,
	prompt_default:   string, // owned: a prompt's default answer
	prompt_focus_due: bool, // its answer field takes the keyboard once its tab is on screen
	nav_started:      time.Tick, // the last main-frame navigation's start (an agent's action stops: page_changed)
	input_at:         time.Tick, // the user's last click, Enter or Space in the page, not yet used by a download (download_take)
	ask_id:           u32, // a download the page started without the user's click, waiting for the bar (0 = none)
	ask_name:         string, // owned: its safe name
	ask_said:         bool, // "refused: one is waiting" was logged for this one
	popups_blocked:   int, // since the bar was last closed
	popup_url:        string, // owned: the last blocked popup's address
	popup_said:       time.Tick, // the last report or log line (at most one a second)
	popup_dirty:      bool, // something to report once a second has passed
	ask_url:          string, // owned: the waiting download's address
	bars_sig:         string, // owned: which bars the tab shows (page_bars_sig)
	bars_changed_at:  time.Tick, // when that changed, or the tab came on screen (bars_click_ok)
	bars_on_screen:   bool, // its bars were on screen at the last note (any pane: one guard per tab)
}

// ---- pure: review round 2 ----

BARS_GUARD :: 500 * time.Millisecond

// Which bars the tab shows, from state (not layout): each bar's kind and its request.
page_bars_sig :: proc(tab_id: u64) -> string {
	b := strings.builder_make(context.temp_allocator)
	if p := page_extras[tab_id]; p != nil {
		if p.crashed do fmt.sbprintf(&b, "crash %d;", p.crash_painted)
		if p.dialog do fmt.sbprintf(&b, "dialog %d %s;", p.dialog_kind, p.dialog_msg)
		if p.perm != 0 do fmt.sbprintf(&b, "perm %d %s;", p.perm, p.perm_origin)
		if p.ask_id != 0 do fmt.sbprintf(&b, "ask %d;", p.ask_id)
		if p.find_open do strings.write_string(&b, "find;")
	}
	if _, tab, _ := find_tab(tab_id); tab != nil {
		if bt, is := tab.kind.(Browser_Tab); is && bt.blocked_popup != "" do fmt.sbprintf(&b, "popup %s;", bt.blocked_popup)
	}
	if d := page_bar_download(tab_id); d != nil do fmt.sbprintf(&b, "download %d %d;", d.id, d.state)
	strings.write_string(&b, browser_act_bar_sig(tab_id)) // an agent's upload (browser_act.odin)
	return strings.to_string(b)
}

// The tab's bars as of now (every frame, and at each click on a bar): bars_changed_at moves
// when its set of bars changed or when it has just come on screen.
bars_note :: proc(tab_id: u64, now: time.Tick) {
	p := page_extra(tab_id)
	if !p.bars_on_screen {
		p.bars_on_screen = true
		p.bars_changed_at = now
	}
	if sig := page_bars_sig(tab_id); sig != p.bars_sig {
		set_owned(&p.bars_sig, sig)
		p.bars_changed_at = now
	}
}

// A click (or Enter in the prompt field) on the tab's bars counts: they have stayed as they are,
// on screen, for BARS_GUARD (a page cannot put a bar under a click meant for something else, nor
// shift one bar under a click meant for another).
bars_click_ok :: proc(tab_id: u64, now: time.Tick) -> bool {
	bars_note(tab_id, now)
	return time.tick_diff(page_extra(tab_id).bars_changed_at, now) >= BARS_GUARD
}

// What a download the page starts gets: Go just after the user's own click or Enter/Space in the
// tab (once: the gesture is used up), Ask otherwise or with DOWNLOADS_PER_TAB running, Refuse
// while one is asking.
download_take :: proc(p: ^Page_Extra, now: time.Tick, going: int) -> Download_Decision {
	if p.ask_id != 0 do return .Refuse
	if going >= DOWNLOADS_PER_TAB do return .Ask
	if p.input_at != {} {
		since := time.tick_diff(p.input_at, now)
		if since >= 0 && since < DOWNLOAD_GESTURE {
			p.input_at = {}
			return .Go
		}
	}
	return .Ask
}

// The download-ask bar's text in room: the origin keeps at least origin_min (clipped from the
// left), the name is clipped in the middle keeping its extension.
ask_bar_text :: proc(origin, name: string, room, origin_min: f32, measure: proc(string) -> f32) -> string {
	PHRASE :: " wants to download "
	full := strings.concatenate({origin, PHRASE, name}, context.temp_allocator)
	if measure(full) <= room do return full
	fixed := measure(PHRASE)
	o_room := max(room - fixed - measure(name), min(measure(origin), origin_min))
	o := clip_left_by(origin, o_room, measure)
	n := clip_middle_keep_ext(name, room - fixed - measure(o), measure)
	return strings.concatenate({o, PHRASE, n}, context.temp_allocator)
}

// name clipped in the middle ("report-2026…final.pdf") to max_w; the extension kept.
clip_middle_keep_ext :: proc(name: string, max_w: f32, measure: proc(string) -> f32) -> string {
	if measure(name) <= max_w do return name
	ext := filepath.ext(name)
	if len(ext) > 16 do ext = ""
	runes := utf8.string_to_runes(name[:len(name) - len(ext)], context.temp_allocator)
	for keep := len(runes) - 1; keep >= 0; keep -= 1 {
		h := (keep + 1) / 2
		cand := strings.concatenate({utf8.runes_to_string(runes[:h], context.temp_allocator), "…", utf8.runes_to_string(runes[len(runes) - (keep - h):], context.temp_allocator), ext}, context.temp_allocator)
		if measure(cand) <= max_w do return cand
	}
	return ""
}

// ---- pure: review round 1 ----

Download_Decision :: enum u8 {
	Go, // the user's click or key in the tab just now: no question
	Ask, // a bar asks first
	Refuse, // one is waiting already
}
DOWNLOAD_GESTURE :: 5 * time.Second

// A popup refused for want of a user gesture: counted; true when it may be reported (and
// logged) now, at most once a second per tab.
popup_blocked_note :: proc(p: ^Page_Extra, url: string, now: time.Tick) -> bool {
	p.popups_blocked += 1
	if url != p.popup_url do set_owned(&p.popup_url, url)
	if p.popup_said == {} || time.tick_diff(p.popup_said, now) >= time.Second {
		p.popup_said, p.popup_dirty = now, false
		return true
	}
	p.popup_dirty = true
	return false
}

DOWNLOADS_PER_TAB :: 20

// s clipped from the left ("…ample.com") to max_w as measure measures it.
clip_left_by :: proc(s: string, max_w: f32, measure: proc(string) -> f32) -> string {
	if max_w <= 0 do return ""
	if measure(s) <= max_w do return s
	rest := s
	for len(rest) > 0 {
		_, n := utf8.decode_rune_in_string(rest)
		rest = rest[n:]
		if measure(strings.concatenate({"…", rest}, context.temp_allocator)) <= max_w do break
	}
	if rest == "" do return ""
	// from a whole label of a host on, when there is one
	if i := strings.index_byte(rest, '.'); i > 0 do rest = rest[i:]
	return strings.concatenate({"…", rest}, context.temp_allocator)
}

// "https://example.com:8443" for any address on it ("file://" for a file; the address itself
// for one without a host).
url_origin :: proc(url: string) -> string {
	i := strings.index(url, "://")
	if i <= 0 do return url
	scheme := strings.to_lower(url[:i], context.temp_allocator)
	if scheme == "file" do return "file://"
	rest := url[i + 3:]
	if k := strings.index_any(rest, "/?#"); k >= 0 do rest = rest[:k]
	if at := strings.last_index_byte(rest, '@'); at >= 0 do rest = rest[at + 1:]
	return strings.concatenate({scheme, "://", strings.to_lower(rest, context.temp_allocator)}, context.temp_allocator)
}

// A JS dialog bar's text: who asks and what.
dialog_bar_text :: proc(kind: Page_Dialog_Kind, msg, origin, page_url: string) -> string {
	#partial switch kind {
	case .Leave:        return "Leave this page? Changes you made may not be saved."
	case .Leave_Reload: return "Reload this page? Changes you made may not be saved."
	}
	page := url_origin(page_url)
	who := origin != "" ? url_origin(origin) : page
	if who != page do who = fmt.tprintf("%s (embedded frame)", who)
	return fmt.tprintf("%s says: %s", one_line(who, context.temp_allocator), one_line(msg, context.temp_allocator))
}

// Why the bar's Open must not open d ("" = it may).
download_open_check :: proc(d: ^Page_Download) -> string {
	if d.state != .Done do return "the download has not finished"
	if !d.quarantined do return "the file is not marked as downloaded (macOS would not check it before it runs): use Show in Finder"
	// files that run a command or open an address when opened
	ext := strings.to_lower(filepath.ext(d.path), context.temp_allocator)
	switch ext {
	case ".command", ".fileloc", ".inetloc", ".webloc", ".terminal", ".tool", ".workflow", ".action", ".mobileconfig":
		return fmt.tprintf("Deckhand does not open %s files: use Show in Finder", ext)
	}
	return ""
}

// CEF's own path for d, when it differs from the one pi-desk gave it.
download_note_path :: proc(d: ^Page_Download, path: string) {
	if path == "" || path == d.path do return
	set_owned(&d.path, path)
	set_owned(&d.name, filepath.base(path))
}

// A new download record for tab_id (at most DOWNLOADS_PER_TAB per tab: the oldest finished go).
download_record :: proc(tab_id: u64, id: u32, path, url: string) -> ^Page_Download {
	if d := download_find(id); d != nil { // an id CEF used before
		download_free(d)
		d^ = Page_Download{id = id, tab_id = tab_id, name = strings.clone(filepath.base(path)), path = strings.clone(path), url = strings.clone(url), state = .Going, total = -1}
		return d
	}
	append(&page_downloads, Page_Download{id = id, tab_id = tab_id, name = strings.clone(filepath.base(path)), path = strings.clone(path), url = strings.clone(url), state = .Going, total = -1})
	for {
		n, oldest := 0, -1
		for d, i in page_downloads do if d.tab_id == tab_id {
			n += 1
			if oldest < 0 && d.state != .Going do oldest = i
		}
		if n <= DOWNLOADS_PER_TAB || oldest < 0 do break
		download_free(&page_downloads[oldest])
		ordered_remove(&page_downloads, oldest)
	}
	return &page_downloads[len(page_downloads) - 1]
}

page_extras: map[u64]^Page_Extra
page_downloads: [dynamic]Page_Download
page_find_field: Text_Field
page_find_tab: u64 // the tab the find field was opened on
page_prompt_field: Text_Field
page_prompt_tab: u64
page_pointer: [2]f32 // the pointer over the page (framebuffer px; the tooltip goes there)
page_pointer_in: bool
page_pointer_tab: u64 // the page the pointer is over (its pane's: its shape and tooltip)
page_revealed: string // test mode: the last download shown in Finder
@(private = "file")
next_download_id: u64
@(private = "file")
callbacks_set: bool

page_extra :: proc(tab_id: u64) -> ^Page_Extra {
	if p := page_extras[tab_id]; p != nil do return p
	p := new(Page_Extra)
	p.tab_id = tab_id
	page_extras[tab_id] = p
	return p
}

@(private = "file")
page_by_cef :: proc(id: c.int) -> (^Browser, ^Page_Extra) {
	for _, b in browsers do if b.cef == id && id != 0 do return b, page_extra(b.tab_id)
	return nil, nil
}

@(private = "file")
set_owned :: proc(dst: ^string, v: string) {
	if dst^ == v do return
	old := dst^
	dst^ = strings.clone(v)
	delete(old)
}

// What belonged to the old browser goes (a page unloaded, reopened, or closed).
@(private = "file")
page_reset :: proc(p: ^Page_Extra) {
	p.crashed, p.dialog, p.perm, p.find_open, p.devtools = false, false, 0, false, false
	p.find_matches, p.find_active, p.zoom_level = 0, 0, 0
	set_owned(&p.dialog_msg, "")
	set_owned(&p.dialog_origin, "")
	set_owned(&p.perm_origin, "")
	set_owned(&p.find_text, "")
	set_owned(&p.tooltip, "")
	set_owned(&p.prompt_default, "")
	p.prompt_focus_due = false
	p.cursor = .DEFAULT
	p.ask_id, p.ask_said = 0, false
	set_owned(&p.ask_name, "")
	set_owned(&p.ask_url, "")
	set_owned(&p.bars_sig, "")
	p.popups_blocked, p.popup_dirty, p.popup_said = 0, false, {}
	set_owned(&p.popup_url, "")
}

@(private = "file")
page_free :: proc(p: ^Page_Extra) {
	page_reset(p)
	free(p)
}

// ---- pure: zoom ----

// Chrome's zoom steps (factors).
ZOOM_FACTORS := [?]f64{0.25, 1.0 / 3, 0.5, 2.0 / 3, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4, 5}

zoom_factor :: proc(level: f64) -> f64 {return math.pow(1.2, level)}
zoom_level :: proc(factor: f64) -> f64 {return math.ln(factor) / math.ln(f64(1.2))}

// The zoom level one step in or out from level (or back to 100%); at the end of the list it stays.
zoom_next :: proc(level: f64, step: Browser_Zoom_Step) -> f64 {
	f := zoom_factor(level)
	switch step {
	case .Reset: return 0
	case .In:
		for z in ZOOM_FACTORS do if z > f + 0.001 do return zoom_level(z)
	case .Out:
		#reverse for z in ZOOM_FACTORS do if z < f - 0.001 do return zoom_level(z)
	}
	return level
}

// The factor as State shows it: 1, 1.1, 1.25, 0.33 (two decimals at most).
zoom_json :: proc(level: f64) -> string {
	s := fmt.tprintf("%.2f", zoom_factor(level))
	s = strings.trim_right(s, "0")
	return strings.trim_right(s, ".")
}

// "125%"
zoom_percent :: proc(level: f64) -> string {return fmt.tprintf("%d%%", int(math.round(zoom_factor(level) * 100)))}

// ---- pure: download names ----

DOWNLOAD_NAME_MAX :: 200 // bytes

// A file name that stays in the downloads folder and shows: no folder part (/ or \), no control,
// direction or invisible characters (one_line's set) or ':' (Finder's /), no leading dots or
// spaces (a hidden file), at most
// DOWNLOAD_NAME_MAX bytes (the extension kept); "download" when nothing is left.
download_safe_name :: proc(suggested: string, allocator := context.temp_allocator) -> string {
	s := suggested
	if i := strings.last_index_any(s, "/\\"); i >= 0 do s = s[i + 1:]
	b := strings.builder_make(context.temp_allocator)
	for r in s {
		switch {
		case rune_breaks_line(r) || r == utf8_error_rune: // control characters, separators, broken UTF-8
		case rune_hidden(r):                                // one_line's set: direction overrides (a name that reads backwards), invisible characters
		case r == ':':                                      strings.write_byte(&b, '_')
		case: strings.write_rune(&b, r)
		}
	}
	out := strings.trim_left(strings.to_string(b), ". \t")
	out = strings.trim_right(out, " \t")
	if out == "" || out == "." || out == ".." do return strings.clone("download", allocator)
	if len(out) > DOWNLOAD_NAME_MAX {
		ext := filepath.ext(out)
		if len(ext) > 16 do ext = ""
		stem := out[:len(out) - len(ext)]
		keep := DOWNLOAD_NAME_MAX - len(ext)
		for keep > 0 && keep < len(stem) && (stem[keep] & 0xC0) == 0x80 do keep -= 1 // a whole character
		out = strings.concatenate({stem[:min(keep, len(stem))], ext}, context.temp_allocator)
	}
	return strings.clone(out, allocator)
}
@(private = "file")
utf8_error_rune :: rune(0xfffd)

// The n-th name tried for name: name, "stem (1).ext", "stem (2).ext", … (a name starting with its
// extension's dot keeps it whole).
download_try_name :: proc(name: string, n: int, allocator := context.temp_allocator) -> string {
	if n == 0 do return strings.clone(name, allocator)
	ext := filepath.ext(name)
	stem := name[:len(name) - len(ext)]
	if stem == "" do stem, ext = name, ""
	return fmt.aprintf("%s (%d)%s", stem, n, ext, allocator = allocator)
}

// A new file in dir for name, made empty now (O_EXCL) so no other download or program takes the
// name before the download lands there: an existing file is never overwritten. "" = none free.
download_reserve :: proc(dir, name: string, allocator := context.temp_allocator) -> string {
	for n in 0 ..< 1000 {
		path, _ := filepath.join({dir, download_try_name(name, n)}, allocator)
		fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.WRONLY, .CREAT, .EXCL, .NOFOLLOW}, {.IRUSR, .IWUSR, .IRGRP, .IROTH})
		if fd >= 0 {
			posix.close(fd)
			return path
		}
		if posix.errno() != .EEXIST do return ""
	}
	return ""
}

// Where downloads go: ~/Downloads; test mode: the data dir's downloads/ (a temp dir).
downloads_dir :: proc() -> string {
	if autotest.active || ODIN_TEST {
		root := home_root != "" ? home_root : "build/test-data"
		d, _ := filepath.join({root, "downloads"}, context.temp_allocator)
		return d
	}
	d, _ := filepath.join({os.get_env("HOME", context.temp_allocator), "Downloads"}, context.temp_allocator)
	return d
}

// A file path as a file:// URL (percent-encoded).
@(private = "file")
file_url :: proc(path: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "file://")
	for i in 0 ..< len(path) {
		ch := path[i]
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-', '_', '.', '~', '/': strings.write_byte(&b, ch)
		case: fmt.sbprintf(&b, "%%%02X", ch)
		}
	}
	return strings.to_string(b)
}

// ---- pure: the right-click and ⋯ menus ----

Menu_Browser :: struct {
	tab_id: u64,
	link:   string, // owned: the link under the pointer ("" = none)
	flags:  c.int, // CM_* (what was under the pointer)
	edit:   c.int, // CM_CAN_*
	x, y:   i32, // the page position (logical px): Inspect
	more:   bool, // the toolbar's ⋯ menu, not the page's
}

browser_menu_items :: proc(t: Menu_Browser, items: ^[dynamic]Menu_Item) {
	_, tab, _ := find_tab(t.tab_id)
	if tab == nil do return
	bt, is := tab.kind.(Browser_Tab)
	if !is do return
	sep :: proc(items: ^[dynamic]Menu_Item) {if len(items) > 0 && !items[len(items) - 1].sep do append(items, Menu_Item{sep = true})}
	p := page_extras[t.tab_id]
	if t.more {
		append(items, Menu_Item{label = "Find in page", keys = "⌘F", action = "browser_find"})
		sep(items)
		level := p != nil ? p.zoom_level : 0
		append(items, Menu_Item{label = fmt.tprintf("Zoom: %s", zoom_percent(level)), note = true})
		append(items, Menu_Item{label = "Zoom in", keys = "⌘+", cmd = Browser_Zoom{t.tab_id, .In}})
		append(items, Menu_Item{label = "Zoom out", keys = "⌘−", cmd = Browser_Zoom{t.tab_id, .Out}})
		append(items, Menu_Item{label = "Actual size", keys = "⌘0", cmd = Browser_Zoom{t.tab_id, .Reset}})
		sep(items)
		if bt.url != "" && bt.url != BROWSER_BLANK do append(items, Menu_Item{label = "Copy URL", copy = bt.url})
		if browser_external_ok(bt.url) do append(items, Menu_Item{label = "Open in default browser", cmd = Browser_External{t.tab_id}})
		sep(items)
		open := p != nil && p.devtools
		append(items, Menu_Item{label = open ? "Close DevTools" : "DevTools", cmd = Browser_Devtools{tab_id = t.tab_id, x = -1, y = -1, close = open}})
		append(items, Menu_Item{label = "Show downloads folder", action = "browser_downloads"})
		return
	}
	if bt.can_back do append(items, Menu_Item{label = "Back", cmd = Browser_Back{t.tab_id}})
	if bt.can_forward do append(items, Menu_Item{label = "Forward", cmd = Browser_Forward{t.tab_id}})
	append(items, Menu_Item{label = "Reload", cmd = Browser_Reload{t.tab_id}})
	if t.link != "" {
		sep(items)
		if s, _, _ := find_tab(t.tab_id); s != nil {
			if _, err := browser_url_normalize(t.link); err == "" && file_link_ok(bt.url, t.link) do append(items, Menu_Item{label = "Open link in new tab", cmd = Browser_Open{session = s.id, url = t.link}})
		}
		append(items, Menu_Item{label = "Copy link", copy = t.link})
	}
	if t.flags & (CM_EDITABLE | CM_SELECTION) != 0 {
		sep(items)
		if t.flags & CM_EDITABLE != 0 && t.edit & CM_CAN_CUT != 0 do append(items, Menu_Item{label = "Cut", keys = "⌘X", cmd = Browser_Edit{t.tab_id, .Cut}})
		if t.edit & CM_CAN_COPY != 0 || t.flags & CM_SELECTION != 0 do append(items, Menu_Item{label = "Copy", keys = "⌘C", cmd = Browser_Edit{t.tab_id, .Copy}})
		if t.flags & CM_EDITABLE != 0 && t.edit & CM_CAN_PASTE != 0 do append(items, Menu_Item{label = "Paste", keys = "⌘V", cmd = Browser_Edit{t.tab_id, .Paste}})
		if t.flags & CM_EDITABLE != 0 do append(items, Menu_Item{label = "Select all", keys = "⌘A", cmd = Browser_Edit{t.tab_id, .Select_All}})
	}
	sep(items)
	append(items, Menu_Item{label = "Inspect", cmd = Browser_Devtools{tab_id = t.tab_id, x = t.x, y = t.y}})
}

// Open in default browser: web addresses only (never a local file or app).
browser_external_ok :: proc(url: string) -> bool {
	l := strings.to_lower(url, context.temp_allocator)
	return strings.has_prefix(l, "http://") || strings.has_prefix(l, "https://")
}

// ---- commands ----

browser_polish_apply :: proc(cmd: Command, caller: Caller) -> (r: Result, changed: bool) {
	target :: proc(tab_id: u64) -> (s: ^Open_Session, bt: ^Browser_Tab, b: ^Browser, err: string) {
		tab: ^Tab
		s, tab, _ = find_tab(tab_id)
		if tab == nil do return nil, nil, nil, "no such tab"
		is: bool
		bt, is = &tab.kind.(Browser_Tab)
		if !is do return nil, nil, nil, "not a browser tab"
		b = browser_of(tab_id)
		return s, bt, b, ""
	}
	live :: proc(b: ^Browser) -> string {return b == nil || b.cef == 0 ? "the page is not loaded" : ""}
	#partial switch c in cmd {
	case Browser_Zoom:
		_, _, b, err := target(c.tab_id)
		if err == "" do err = live(b)
		if err != "" do return fail(err), false
		p := page_extra(c.tab_id)
		level := zoom_next(pd_cef_zoom_get(b.cef), c.step)
		pd_cef_zoom_set(b.cef, level)
		p.zoom_level = level
		page_zoom_to_annot(c.tab_id, level)
		return {ok = true}, true
	case Browser_Find:
		_, _, b, err := target(c.tab_id)
		if err == "" do err = live(b)
		if err != "" do return fail(err), false
		p := page_extra(c.tab_id)
		again := p.find_open && c.text == p.find_text && c.text != ""
		p.find_open = true
		set_owned(&p.find_text, c.text)
		if c.text == "" {
			pd_cef_find_stop(b.cef)
			p.find_matches, p.find_active = 0, 0
		} else {
			t := strings.clone_to_cstring(c.text, context.temp_allocator)
			// a new text: CEF's first request (a new session) highlights without selecting; the
			// follow-up selects the first match, as typing in Chrome's find bar does
			if !again do pd_cef_find(b.cef, t, c.back ? 0 : 1, 0)
			pd_cef_find(b.cef, t, c.back ? 0 : 1, 1)
		}
		return {ok = true}, true
	case Browser_Find_Close:
		_, _, b, err := target(c.tab_id)
		if err != "" do return fail(err), false
		p := page_extra(c.tab_id)
		if b != nil && b.cef != 0 do pd_cef_find_stop(b.cef)
		p.find_open, p.find_matches, p.find_active = false, 0, 0
		set_owned(&p.find_text, "")
		if state.focus_widget == "browser_find" && page_find_tab == c.tab_id {
			delete(state.focus_widget)
			state.focus_widget = ""
		}
		return {ok = true}, true
	case Browser_Dialog:
		_, _, b, err := target(c.tab_id)
		if err == "" do err = live(b)
		if err != "" do return fail(err), false
		p := page_extra(c.tab_id)
		if !p.dialog || pd_cef_dialog_answer(b.cef, c.ok ? 1 : 0, strings.clone_to_cstring(c.text, context.temp_allocator)) == 0 do return fail("no dialog is open"), false
		page_dialog_clear(p) // and the answer field, when it was this tab's
		return {ok = true}, true
	case Browser_Permission:
		_, _, b, err := target(c.tab_id)
		if err == "" do err = live(b)
		if err != "" do return fail(err), false
		p := page_extra(c.tab_id)
		if p.perm == 0 || pd_cef_permission_answer(b.cef, c.allow ? 1 : 0) == 0 do return fail("nothing is asked"), false
		p.perm = 0
		set_owned(&p.perm_origin, "")
		return {ok = true}, true
	case Browser_Popup:
		s, bt, _, err := target(c.tab_id)
		if err != "" do return fail(err), false
		if bt.blocked_popup == "" do return fail("no popup was blocked"), false
		url := strings.clone(bt.blocked_popup, context.temp_allocator)
		set_owned(&bt.blocked_popup, "")
		if p := page_extras[c.tab_id]; p != nil {
			p.popups_blocked, p.popup_dirty = 0, false
			set_owned(&p.popup_url, "")
		}
		if !c.open do return {ok = true}, true
		// the page's own address for it: an address pi-desk opens (http, https, file, pidesk-test)
		nurl, nerr := browser_url_normalize(url)
		if nerr != "" do return fail(nerr), true
		if !file_link_ok(bt.url, nurl) do return fail("a file: address opens from a file: page only"), true
		// a new tab in the opener's session (never another), on screen there
		id, oerr := browser_tab_open(s.id, nurl)
		if id == 0 do return fail(oerr), true
		return {ok = true, created_id = id}, true
	case Browser_Edit:
		_, _, b, err := target(c.tab_id)
		if err == "" do err = live(b)
		if err != "" do return fail(err), false
		pd_cef_edit(b.cef, i32(c.op))
		return {ok = true}, false
	case Browser_Devtools:
		_, _, b, err := target(c.tab_id)
		if err == "" do err = live(b)
		if err != "" do return fail(err), false
		p := page_extra(c.tab_id)
		if c.close {
			pd_cef_devtools_close(b.cef)
			p.devtools = false
		} else {
			if pd_cef_devtools_show(b.cef, c.x, c.y) == 0 do return fail("DevTools could not open"), false
			p.devtools = true
		}
		return {ok = true}, true
	case Browser_External:
		_, bt, _, err := target(c.tab_id)
		if err != "" do return fail(err), false
		if !browser_external_ok(bt.url) do return fail("only web addresses (http, https) open in the default browser"), false
		if platform.open_url == nil || !platform.open_url(bt.url) do return fail("the page could not be opened in the default browser"), false
		return {ok = true}, false
	case Browser_Download:
		if c.download_id == 0 && c.op == .Reveal {
			// the downloads folder itself (⋯'s Show downloads folder)
			dir := downloads_dir()
			os.make_directory_all(dir)
			set_owned(&page_revealed, dir)
			if platform.reveal != nil do platform.reveal(dir)
			return {ok = true}, false
		}
		if c.op == .Allow || c.op == .Block {
			// a download the page started without the user's click (download_ask)
			for tab_id, p in page_extras {
				if p.ask_id == 0 || u64(p.ask_id) != c.download_id do continue
				b := browser_of(tab_id)
				id := p.ask_id
				p.ask_id, p.ask_said = 0, false
				name := strings.clone(p.ask_name, context.temp_allocator)
				url := strings.clone(p.ask_url, context.temp_allocator)
				set_owned(&p.ask_name, "")
				set_owned(&p.ask_url, "")
				if b == nil || b.cef == 0 do return fail("the page is not loaded"), true
				if c.op == .Block {
					pd_cef_download_answer(b.cef, id, nil)
					fmt.printfln("[browser] download %d blocked: %s", id, name)
					return {ok = true}, true
				}
				dir := downloads_dir()
				os.make_directory_all(dir)
				path := download_reserve(dir, name)
				if path == "" {
					pd_cef_download_answer(b.cef, id, nil)
					return fail(fmt.tprintf("no free name for %q in the downloads folder", name)), true
				}
				download_record(tab_id, id, path, url)
				if pd_cef_download_answer(b.cef, id, strings.clone_to_cstring(path, context.temp_allocator)) == 0 && CEF_BUILT_IN {
					os.remove(path) // CEF no longer waits for it: the empty file goes
					if d := download_find(id); d != nil do d.state = .Failed
					return fail("the download is gone"), true
				}
				fmt.printfln("[browser] download %d allowed -> %s", id, path)
				return {ok = true}, true
			}
			return fail("no download is waiting for an answer"), false
		}
		d := download_find(u32(c.download_id))
		if d == nil do return fail("no such download"), false
		switch c.op {
		case .Open:
			if err := download_open_check(d); err != "" do return fail(err), false
			if platform.open_url == nil || !platform.open_url(file_url(d.path)) do return fail("the file could not be opened"), false
		case .Reveal:
			if !os.exists(d.path) do return fail("the file is gone"), false
			set_owned(&page_revealed, d.path)
			if platform.reveal != nil do platform.reveal(d.path)
		case .Cancel:
			if d.state != .Going do return fail("the download is not running"), false
			pd_cef_download_cancel(d.id)
		case .Dismiss:
			d.dismissed = true
		case .Allow, .Block: // above
		}
		return {ok = true}, c.op == .Dismiss
	}
	return fail("unknown command"), false
}

@(private = "file")
page_dialog_clear :: proc(p: ^Page_Extra) {
	p.dialog, p.prompt_focus_due = false, false
	set_owned(&p.dialog_msg, "")
	set_owned(&p.dialog_origin, "")
	if state.focus_widget == "browser_prompt" && page_prompt_tab == p.tab_id {
		delete(state.focus_widget)
		state.focus_widget = ""
	}
	// the shared answer field forgets what was typed for this tab
	if page_prompt_tab == p.tab_id {
		tf_set(&page_prompt_field, "")
		page_prompt_tab = 0
	}
}

// A file: address opens from a file: page only (the popup bar, Open link in new tab).
file_link_ok :: proc(page_url, link: string) -> bool {
	is_file :: proc(u: string) -> bool {return strings.has_prefix(strings.to_lower(u, context.temp_allocator), "file:")}
	return !is_file(link) || is_file(page_url)
}

// A popup refused for want of a user gesture (browser.odin's on_cef_popup): counted, and the
// bar and the log follow at most once a second (popup_blocked_note; the rest: browser_polish_tick).
browser_popup_refused :: proc(tab_id: u64, url: string) {
	p := page_extra(tab_id)
	if popup_blocked_note(p, url, time.tick_now()) do popup_report(tab_id, p)
}

@(private = "file")
popup_report :: proc(tab_id: u64, p: ^Page_Extra) {
	fmt.printfln("[browser] popup without a user gesture refused: %s (%d blocked)", p.popup_url, p.popups_blocked)
	browser_report({tab_id = tab_id, what = {.Blocked}, blocked = p.popup_url})
}

download_find :: proc(id: u32) -> ^Page_Download {
	for &d in page_downloads do if d.id == id do return &d
	return nil
}

browser_polish_command_type :: proc(cmd: Command) -> string {
	#partial switch _ in cmd {
	case Browser_Zoom:       return "browser_zoom"
	case Browser_Find:       return "browser_find"
	case Browser_Find_Close: return "browser_find_close"
	case Browser_Dialog:     return "browser_dialog"
	case Browser_Permission: return "browser_permission"
	case Browser_Popup:      return "browser_popup"
	case Browser_Edit:       return "browser_edit"
	case Browser_Devtools:   return "browser_devtools"
	case Browser_External:   return "browser_external"
	case Browser_Download:   return "browser_download"
	}
	return ""
}

browser_polish_command_clone :: proc(cmd: Command, allocator: runtime.Allocator) -> Command {
	#partial switch c in cmd {
	case Browser_Find:
		x := c
		x.text = strings.clone(c.text, allocator)
		return x
	case Browser_Dialog:
		x := c
		x.text = strings.clone(c.text, allocator)
		return x
	}
	return cmd
}

browser_polish_command_free :: proc(cmd: Command, allocator: runtime.Allocator) {
	#partial switch c in cmd {
	case Browser_Find:   delete(c.text, allocator)
	case Browser_Dialog: delete(c.text, allocator)
	}
}

// The command's fields for events and logs (redact: a prompt's answer becomes its length).
browser_polish_command_write :: proc(w: ^Jw, cmd: Command, redact := false) {
	#partial switch c in cmd {
	case Browser_Zoom:
		pw_u64(w, "tab_id", c.tab_id)
		pw_str(w, "step", BROWSER_ZOOM_STEP_NAMES[c.step])
	case Browser_Find:
		pw_u64(w, "tab_id", c.tab_id)
		pw_str(w, "text", c.text)
		if c.back do pw_bool(w, "back", true)
	case Browser_Find_Close: pw_u64(w, "tab_id", c.tab_id)
	case Browser_Dialog:
		pw_u64(w, "tab_id", c.tab_id)
		pw_bool(w, "ok", c.ok)
		if c.text != "" do pw_str(w, "text", redact ? fmt.tprintf("<redacted %d bytes>", len(c.text)) : c.text)
	case Browser_Permission:
		pw_u64(w, "tab_id", c.tab_id)
		pw_bool(w, "allow", c.allow)
	case Browser_Popup:
		pw_u64(w, "tab_id", c.tab_id)
		pw_bool(w, "open", c.open)
	case Browser_Edit:
		pw_u64(w, "tab_id", c.tab_id)
		pw_str(w, "op", BROWSER_EDIT_OP_NAMES[c.op])
	case Browser_Devtools:
		pw_u64(w, "tab_id", c.tab_id)
		if c.x >= 0 && c.y >= 0 {
			pw_u64(w, "x", u64(c.x))
			pw_u64(w, "y", u64(c.y))
		}
		if c.close do pw_bool(w, "close", true)
	case Browser_External: pw_u64(w, "tab_id", c.tab_id)
	case Browser_Download:
		pw_u64(w, "download_id", c.download_id)
		pw_str(w, "op", BROWSER_DOWNLOAD_OP_NAMES[c.op])
	}
}

@(private = "file")
pw_key :: proc(w: ^Jw, k: string) {
	if !w.first do strings.write_byte(w.b, ',')
	w.first = false
	json_quote(w.b, k)
	strings.write_byte(w.b, ':')
}
@(private = "file")
pw_str :: proc(w: ^Jw, k, v: string) {pw_key(w, k); json_quote(w.b, v)}
@(private = "file")
pw_u64 :: proc(w: ^Jw, k: string, v: u64) {pw_key(w, k); strings.write_u64(w.b, v)}
@(private = "file")
pw_bool :: proc(w: ^Jw, k: string, v: bool) {pw_key(w, k); strings.write_string(w.b, v ? "true" : "false")}

// ---- State (json_write.odin, inside a browser tab's object) ----

// `,"zoom":1.25,"crashed":false,"devtools":false` and, while shown, `"dialog"`, `"permission"`,
// `"find"`, `"downloads"` (this tab's).
browser_polish_tab_json :: proc(b: ^strings.Builder, tab_id: u64) {
	p := page_extras[tab_id]
	level := p != nil ? p.zoom_level : 0
	fmt.sbprintf(b, `,"zoom":%s,"crashed":%v,"devtools":%v`, zoom_json(level), p != nil && p.crashed, p != nil && p.devtools)
	if p == nil do return
	if p.dialog {
		fmt.sbprintf(b, `,"dialog":{{"kind":"%s","message":`, PAGE_DIALOG_NAMES[p.dialog_kind])
		json_quote(b, p.dialog_msg)
		strings.write_string(b, `,"origin":`)
		json_quote(b, p.dialog_origin)
		strings.write_byte(b, '}')
	}
	if p.perm != 0 {
		strings.write_string(b, `,"permission":{"what":`)
		json_quote(b, perm_names(p.perm, ","))
		strings.write_string(b, `,"origin":`)
		json_quote(b, p.perm_origin)
		strings.write_byte(b, '}')
	}
	if p.ask_id != 0 {
		fmt.sbprintf(b, `,"download_ask":{{"id":%d,"name":`, p.ask_id)
		json_quote(b, p.ask_name)
		strings.write_byte(b, '}')
	}
	if p.popups_blocked > 0 do fmt.sbprintf(b, `,"popups_blocked":%d`, p.popups_blocked)
	if p.find_open {
		strings.write_string(b, `,"find":{"text":`)
		json_quote(b, p.find_text)
		fmt.sbprintf(b, `,"matches":%d,"active":%d}}`, p.find_matches, p.find_active)
	}
	n := 0
	for d in page_downloads {
		if d.tab_id != tab_id do continue
		strings.write_string(b, n == 0 ? `,"downloads":[` : ",")
		n += 1
		fmt.sbprintf(b, `{{"id":%d,"name":`, d.id)
		json_quote(b, d.name)
		strings.write_string(b, `,"path":`)
		json_quote(b, d.path)
		fmt.sbprintf(b, `,"state":"%s","received":%d,"total":%d,"dismissed":%v,"quarantined":%v}}`, DOWNLOAD_STATE_NAMES[d.state], d.received, d.total, d.dismissed, d.quarantined)
	}
	if n > 0 do strings.write_byte(b, ']')
}

// "notifications", "camera,microphone", …
perm_names :: proc(bits: u32, sep: string) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if bits & PERM_NOTIFICATIONS != 0 do append(&parts, "notifications")
	if bits & PERM_GEOLOCATION != 0 do append(&parts, "location")
	if bits & PERM_CAMERA != 0 do append(&parts, "camera")
	if bits & PERM_MIC != 0 do append(&parts, "microphone")
	return strings.join(parts[:], sep, context.temp_allocator)
}

// The permission bar's wording: "show notifications", "use your camera and microphone".
perm_phrase :: proc(bits: u32) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	if bits & PERM_NOTIFICATIONS != 0 do append(&parts, "show notifications")
	if bits & PERM_GEOLOCATION != 0 do append(&parts, "know your location")
	media := make([dynamic]string, context.temp_allocator)
	if bits & PERM_CAMERA != 0 do append(&media, "camera")
	if bits & PERM_MIC != 0 do append(&media, "microphone")
	if len(media) > 0 do append(&parts, fmt.tprintf("use your %s", strings.join(media[:], " and ", context.temp_allocator)))
	return strings.join(parts[:], " and ", context.temp_allocator)
}

// ---- CEF's reports (the shim, on the main thread during the pump) ----

@(private = "file")
on_page_cursor :: proc "c" (id: c.int, type: c.int) {
	context = app_context
	b, p := page_by_cef(id)
	if b == nil do return
	p.cursor = cef_cursor(int(type))
	if b.tab_id == page_pointer_tab && page_pointer_in && !annot_on(b) && sapp.get_mouse_cursor() != p.cursor do sapp.set_mouse_cursor(p.cursor)
}

// cef_cursor_type_t -> sokol's pointer shapes (the nearest; the rest: the arrow).
cef_cursor :: proc(type: int) -> sapp.Mouse_Cursor {
	switch type {
	case 1:            return .CROSSHAIR // CT_CROSS
	case 2:            return .POINTING_HAND // CT_HAND
	case 3, 34:        return .IBEAM // CT_IBEAM, CT_VERTICALTEXT
	case 6, 13, 18:    return .RESIZE_EW // east, west, east-west resize
	case 19:           return .RESIZE_EW // column resize
	case 7, 10, 14:    return .RESIZE_NS // north, south, north-south
	case 20:           return .RESIZE_NS // row resize
	case 8, 12, 15:    return .RESIZE_NESW // north-east, south-west, NE-SW
	case 9, 11, 16:    return .RESIZE_NWSE
	case 32:           return .RESIZE_ALL // CT_MOVE
	case 35:           return .CROSSHAIR // CT_CELL
	case 41, 43:       return .NOT_ALLOWED // CT_NODROP, CT_NOTALLOWED
	}
	return .DEFAULT
}

@(private = "file")
on_page_tooltip :: proc "c" (id: c.int, utf8: cstring) {
	context = app_context
	b, p := page_by_cef(id)
	if b == nil do return
	set_owned(&p.tooltip, cut_utf8(one_line(string(utf8), context.temp_allocator), 300))
	app.redraw = true
}

@(private = "file")
on_page_menu :: proc "c" (id: c.int, flags, edit: c.int, link: cstring) {
	context = app_context
	b, _ := page_by_cef(id)
	if b == nil || b != tab_browser() || annot_on(b) do return
	// an agent's right-click: the page has its contextmenu event, the user gets no menu (browser_act.odin)
	if browser_act_busy(b.tab_id) {
		fmt.printfln("[browser] tab %d: no menu for an agent's right-click", b.tab_id)
		return
	}
	// the right button's release may never reach the page now (the menu takes the input): let go
	RIGHT :: c.int(1 << 6)
	if b.buttons & RIGHT != 0 {
		b.buttons &~= RIGHT
		pd_cef_mouse_click(b.cef, b.last_x, b.last_y, b.buttons, 2, 1, 1)
	}
	r := tab_rect(b.tab_id)
	at := [2]f32{r.x + f32(b.last_x) * app.dpi, r.y + f32(b.last_y) * app.dpi}
	menu_open(Menu_Browser{tab_id = b.tab_id, link = string(link), flags = flags, edit = edit, x = i32(b.last_x), y = i32(b.last_y)}, at)
}

@(private = "file")
on_page_dialog :: proc "c" (id: c.int, kind: c.int, message, default_text, origin: cstring) {
	context = app_context
	b, p := page_by_cef(id)
	if b == nil do return
	if kind < 0 {
		if !p.dialog do return
		page_dialog_clear(p)
	} else {
		p.dialog = true
		p.dialog_kind = Page_Dialog_Kind(clamp(int(kind), 0, len(Page_Dialog_Kind) - 1))
		set_owned(&p.dialog_msg, cut_utf8(string(message), 2000))
		set_owned(&p.dialog_origin, string(origin))
		set_owned(&p.prompt_default, string(default_text))
		// a prompt's answer field takes the keyboard (now, or when its tab is shown: browser_polish_tick)
		p.prompt_focus_due = p.dialog_kind == .Prompt
		// the shared answer field starts from this prompt's default, unless another tab's
		// prompt is being typed into (this one's then shows its default until its field is used)
		if p.dialog_kind == .Prompt && (page_prompt_tab == b.tab_id || state.focus_widget != "browser_prompt") {
			tf_set(&page_prompt_field, p.prompt_default)
			tf_select_all(&page_prompt_field)
			page_prompt_tab = b.tab_id
		}
	}
	browser_report({tab_id = b.tab_id})
	app.redraw = true
}

@(private = "file")
on_page_find :: proc "c" (id: c.int, request, count, active, final_update: c.int) {
	context = app_context
	b, p := page_by_cef(id)
	if b == nil || !p.find_open do return
	p.find_matches = int(count)
	if active > 0 do p.find_active = int(active)
	if count == 0 do p.find_active = 0
	if final_update != 0 do browser_report({tab_id = b.tab_id})
	app.redraw = true
}

@(private = "file")
on_page_download_path :: proc "c" (id: c.int, dl: u32, suggested, url: cstring, out: [^]u8, cap: c.int) -> c.int {
	context = app_context
	b, p := page_by_cef(id)
	if b == nil do return 0 // not a tab's page
	name := download_safe_name(string(suggested))
	going := 0
	for d in page_downloads do if d.tab_id == b.tab_id && d.state == .Going do going += 1
	switch download_take(p, time.tick_now(), going) {
	case .Refuse:
		if !p.ask_said do fmt.printfln("[browser] tab %d: download refused (%s): another one is waiting for an answer", b.tab_id, name)
		p.ask_said = true
		return 0
	case .Ask:
		// not just after the user's click or key in this tab: the bar asks first
		p.ask_id, p.ask_said = dl, false
		set_owned(&p.ask_name, name)
		set_owned(&p.ask_url, string(url))
		fmt.printfln("[browser] download %d asks first: %s", dl, name)
		browser_report({tab_id = b.tab_id})
		app.redraw = true
		return 2
	case .Go:
	}
	dir := downloads_dir()
	os.make_directory_all(dir)
	path := download_reserve(dir, name)
	if path == "" || len(path) + 1 > int(cap) {
		fmt.printfln("[browser] download refused: no free name for %q in %s", name, dir)
		return 0
	}
	copy(out[:len(path)], path)
	out[len(path)] = 0
	download_record(b.tab_id, dl, path, string(url))
	fmt.printfln("[browser] download %d -> %s", dl, path)
	browser_report({tab_id = b.tab_id})
	return 1
}

@(private = "file")
download_free :: proc(d: ^Page_Download) {
	delete(d.name)
	delete(d.path)
	delete(d.url)
	d.name, d.path, d.url = "", "", ""
}

@(private = "file")
on_page_download :: proc "c" (id: c.int, dl: u32, st: c.int, received, total: i64, path: cstring, quarantined: c.int) {
	context = app_context
	d := download_find(dl)
	if d == nil do return // not one pi-desk named (refused, or waiting for its bar)
	was := d.state
	d.received, d.total = received, total
	download_note_path(d, string(path)) // CEF's own, when it differs
	if st == 2 do d.quarantined = quarantined != 0
	switch st {
	case 2: d.state = .Done
	case 3: d.state = .Cancelled
	case 4: d.state = .Failed
	case:   d.state = .Going
	}
	if d.state != was {
		if d.state == .Cancelled || d.state == .Failed {
			// the empty file that held its name goes (never anything with content)
			if fi, err := os.stat(d.path, context.temp_allocator); err == nil && fi.size == 0 do os.remove(d.path)
		}
		fmt.printfln("[browser] download %d %s: %s (%d bytes)", dl, DOWNLOAD_STATE_NAMES[d.state], d.path, received)
	}
	if d.tab_id != 0 && (d.state != was || d.state == .Going) do browser_report({tab_id = d.tab_id})
	app.redraw = true
}

@(private = "file")
on_page_permission :: proc "c" (id: c.int, what: u32, origin: cstring) {
	context = app_context
	b, p := page_by_cef(id)
	if b == nil do return
	p.perm = what
	set_owned(&p.perm_origin, string(origin))
	browser_report({tab_id = b.tab_id})
	app.redraw = true
}

@(private = "file")
on_page_crashed :: proc "c" (id: c.int, status: c.int) {
	context = app_context
	b, p := page_by_cef(id)
	if b == nil do return
	p.crashed, p.crash_status, p.crash_painted = true, int(status), b.painted
	p.find_matches, p.find_active = 0, 0
	set_owned(&p.tooltip, "")
	fmt.printfln("[browser] tab %d: the page's renderer died (status %d)", b.tab_id, status)
	browser_report({tab_id = b.tab_id})
	app.redraw = true
}

// A native file chooser opening: cancelled while an agent's action runs on the tab
// (browser_act_file_dialog); the user's own click gets the panel.
@(private = "file")
on_page_file_dialog :: proc "c" (id: c.int) -> c.int {
	context = app_context
	b, _ := page_by_cef(id)
	if b == nil do return 0
	return browser_act_file_dialog(b.tab_id) ? 1 : 0
}

// A main-frame navigation: a download still asking is cancelled and its bar goes; the
// blocked-popup count starts again.
@(private = "file")
on_page_navigated :: proc "c" (id: c.int) {
	context = app_context
	b, p := page_by_cef(id)
	if b == nil do return
	p.nav_started = time.tick_now()
	changed := false
	if p.ask_id != 0 {
		pd_cef_download_answer(b.cef, p.ask_id, nil)
		fmt.printfln("[browser] download %d dropped: the page navigated (%s)", p.ask_id, p.ask_name)
		p.ask_id, p.ask_said = 0, false
		set_owned(&p.ask_name, "")
		set_owned(&p.ask_url, "")
		changed = true
	}
	if p.popups_blocked > 0 {
		p.popups_blocked, p.popup_dirty = 0, false
		changed = true
	}
	if changed {
		browser_report({tab_id = b.tab_id})
		app.redraw = true
	}
}

// ---- every frame (main.odin, after annot_tick) ----

browser_polish_tick :: proc() {
	if !callbacks_set && CEF_BUILT_IN {
		callbacks_set = true
		@(static) cbs := Cef_Polish_Callbacks {
			cursor        = on_page_cursor,
			tooltip       = on_page_tooltip,
			context_menu  = on_page_menu,
			dialog        = on_page_dialog,
			find          = on_page_find,
			download_path = on_page_download_path,
			download      = on_page_download,
			permission    = on_page_permission,
			crashed       = on_page_crashed,
			navigated     = on_page_navigated,
			file_dialog   = on_page_file_dialog,
		}
		pd_cef_polish_callbacks_set(&cbs)
	}
	if len(page_extras) == 0 && len(browsers) == 0 do return
	gone := make([dynamic]u64, context.temp_allocator)
	for id in page_extras do if browsers[id] == nil do append(&gone, id)
	for id in gone {
		page_free(page_extras[id])
		delete_key(&page_extras, id)
	}
	on_screen := tab_browser() // the focused pane's page: its find and prompt fields
	for id, b in browsers {
		p := page_extra(id)
		if b.cef != p.cef {
			had := p.cef != 0
			p.cef = b.cef
			page_reset(p)
			if had do browser_report({tab_id = id})
		}
		if b.cef == 0 do continue
		// a crashed page painting again (Reload) is a live page again
		if p.crashed && b.painted > p.crash_painted {
			p.crashed = false
			browser_report({tab_id = id})
		}
		if !tab_on_screen(id) do continue // every page on screen (any pane's)
		// zoom is Chromium's per host (another tab, a navigation): follow it
		if pd_cef_ready(b.cef) != 0 {
			if z := pd_cef_zoom_get(b.cef); abs(z - p.zoom_level) > 0.0001 {
				p.zoom_level = z
				browser_report({tab_id = id})
			}
			if d := pd_cef_devtools_open(b.cef) != 0; d != p.devtools {
				p.devtools = d
				browser_report({tab_id = id})
			}
		}
		page_zoom_to_annot(id, p.zoom_level)
	}
	// the find field and the prompt field belong to the tab they were opened on, while it has the keyboard (panes.odin)
	if state.focus_widget == "browser_find" && !tab_focused(page_find_tab) do ui_do(Set_Focus{""})
	if state.focus_widget == "browser_prompt" && !tab_focused(page_prompt_tab) do ui_do(Set_Focus{""})
	// the find field searches as it is typed
	if state.focus_widget == "browser_find" && on_screen != nil {
		p := page_extra(on_screen.tab_id)
		if t := tf_text(&page_find_field); p.find_open && t != p.find_text do ui_do(Browser_Find{tab_id = on_screen.tab_id, text = t})
	}
	// a prompt that came while its tab was not on screen: its field takes the keyboard when shown
	if on_screen != nil && state.focus_widget == "" {
		if p := page_extras[on_screen.tab_id]; p != nil && p.prompt_focus_due && p.dialog && p.dialog_kind == .Prompt {
			p.prompt_focus_due = false
			tf_set(&page_prompt_field, p.prompt_default)
			tf_select_all(&page_prompt_field)
			page_prompt_tab = on_screen.tab_id
			ui_do(Set_Focus{"browser_prompt"})
		}
	}
}

// Every frame, drawn or not (main.odin, before its redraw check): blocked popups held back by
// the once-a-second limit are reported once the second has passed. True: something changed.
browser_polish_pending_tick :: proc() -> bool {
	changed := false
	// the bars' click guard follows every tab on screen and its bars (bars_note); one that left
	// the screen starts again when it comes back
	now := time.tick_now()
	for id, b in browsers do if tab_on_screen(id) do bars_note(b.tab_id, now)
	for id, p in page_extras do if p.bars_on_screen && !tab_on_screen(id) do p.bars_on_screen = false
	for id, p in page_extras {
		if !p.popup_dirty || time.tick_diff(p.popup_said, time.tick_now()) < time.Second do continue
		p.popup_said, p.popup_dirty = time.tick_now(), false
		if browsers[id] != nil && browsers[id].cef != 0 do popup_report(id, p)
		changed = true
	}
	return changed
}

// Comment mode maps CSS px to the tab with the page's zoom (browser_annotate.odin).
@(private = "file")
page_zoom_to_annot :: proc(tab_id: u64, level: f64) {
	if a := annot_of(tab_id); a != nil {
		z := f32(zoom_factor(level))
		if a.zoom != z {
			a.zoom = z
			app.redraw = true
		}
	}
}

// ---- the find bar ----

// The find bar opens on the tab on screen (⌘F, Find in page) with the keyboard in its field.
browser_find_open :: proc() {
	if tab_browser() == nil do return
	action_run("browser_find")
}

// The find action's UI step: the field holds the tab's text, selected; the bar opens.
browser_find_prepare :: proc() {
	b := tab_browser()
	if b == nil || b.cef == 0 do return
	p := page_extra(b.tab_id)
	tf_set(&page_find_field, p.find_text)
	tf_select_all(&page_find_field)
	page_find_tab = b.tab_id
	if !p.find_open do ui_do(Browser_Find{tab_id = b.tab_id, text = p.find_text})
}

// The zoom actions (palette, View menu): the tab on screen.
browser_zoom_action :: proc(step: Browser_Zoom_Step) -> (Command, bool) {
	b := tab_browser()
	if b == nil || b.cef == 0 do return nil, false
	return Browser_Zoom{b.tab_id, step}, true
}

@(private = "file")
find_step :: proc(back: bool) {
	b := tab_browser()
	if b == nil do return
	p := page_extra(b.tab_id)
	text := p.find_text
	if state.focus_widget == "browser_find" && page_find_tab == b.tab_id do text = tf_text(&page_find_field)
	if text == "" do return
	ui_do(Browser_Find{tab_id = b.tab_id, text = text, back = back})
}

// ---- input (main.odin: after the URL field's keys, before the widgets and the page) ----

@(private = "file")
over_overlay :: proc() -> bool {
	return palette_is_open() || menu.open || settings_open() || shortcuts_open() || setup_open() || job_sheet_open()
}

@(private = "file")
hit :: proc(name: string, e: ^sapp.Event) -> bool {return inside(cid(name), e.mouse_x, e.mouse_y)}

// The user's own click or key reached the page (browser.odin, as it sends it): a download the
// page starts in the next DOWNLOAD_GESTURE goes without asking, once (download_take).
// Only browser.odin's handling of the user's own events calls this: never an agent's command
// (step 8's clicks and keys must not either; test browser_agent_commands_are_not_a_gesture).
browser_page_input :: proc(tab_id: u64) {
	page_extra(tab_id).input_at = time.tick_now()
}

// The answer a prompt bar's OK sends: the field's text only when the field is this tab's.
@(private = "file")
page_prompt_answer :: proc(tab_id: u64, p: ^Page_Extra) -> string {
	return page_prompt_tab == tab_id ? tf_text(&page_prompt_field) : p.prompt_default
}

// The bars, for their click guards.
Pg_Bar :: enum u8 {
	None,
	Crash,
	Dialog,
	Perm,
	Popup,
	Ask,
	Download,
	Find,
	Upload,
}
PG_BAR_NAMES := [Pg_Bar]string {
	.None     = "",
	.Crash    = "pg_crash",
	.Dialog   = "pg_dialog",
	.Perm     = "pg_perm",
	.Popup    = "pg_popup",
	.Ask      = "pg_dlask",
	.Download = "pg_dl",
	.Find     = "pg_find",
	.Upload   = "pg_upload",
}

// The bar whose button is under the pointer (its fields are not guarded: a click there only
// places the caret).
@(private = "file")
pg_bar_at :: proc(e: ^sapp.Event) -> Pg_Bar {
	for bar in Pg_Bar {
		if bar == .None || !hit(PG_BAR_NAMES[bar], e) do continue
		if hit("pg_find_box", e) || hit("pg_prompt_box", e) do return .None
		return bar
	}
	return .None
}

// The bars' buttons and fields, ⋯ and the zoom chip, ⌘F ⌘G ⌘+ ⌘− ⌘0, Enter and Esc in the find and
// prompt fields; the pointer's shape over the page. True if it took the event.
browser_polish_event :: proc(pn: ^Pane, e: ^sapp.Event) -> bool {
	b := pane_browser(pn)
	if b == nil {
		if e.type == .MOUSE_MOVE && page_pointer_in { // over another pane now: no page's tooltip
			page_pointer_in, page_pointer_tab = false, 0
			app.redraw = true
		}
		return false
	}
	p := page_extra(b.tab_id)
	mods := e.modifiers & (sapp.MODIFIER_SUPER | sapp.MODIFIER_CTRL | sapp.MODIFIER_ALT | sapp.MODIFIER_SHIFT)
	#partial switch e.type {
	case .KEY_DOWN:
		if over_overlay() do return false
		w := state.focus_widget
		page_keys := w == "" || w == "browser_url" || w == "browser_find" || w == "browser_prompt"
		if page_keys && mods & sapp.MODIFIER_SUPER != 0 && b.cef != 0 {
			only_cmd := mods == sapp.MODIFIER_SUPER
			took := true
			#partial switch e.key_code {
			case .F:     if only_cmd do browser_find_open(); else do took = false
			case .G:     if p.find_open && (only_cmd || mods == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT) do find_step(mods & sapp.MODIFIER_SHIFT != 0); else do took = false
			case .EQUAL: if only_cmd || mods == sapp.MODIFIER_SUPER | sapp.MODIFIER_SHIFT do ui_do(Browser_Zoom{b.tab_id, .In}); else do took = false // ⌘+ is ⌘= (with Shift or not)
			case .MINUS: if only_cmd do ui_do(Browser_Zoom{b.tab_id, .Out}); else do took = false
			case ._0:    if only_cmd do ui_do(Browser_Zoom{b.tab_id, .Reset}); else do took = false
			case: took = false
			}
			if took {
				app.key_taken = true
				app.redraw = true
				return true
			}
		}
		if w == "browser_find" && page_find_tab == b.tab_id {
			#partial switch e.key_code {
			case .ENTER, .KP_ENTER:
				find_step(mods & sapp.MODIFIER_SHIFT != 0)
				app.key_taken = true
				return true
			case .ESCAPE:
				ui_do(Browser_Find_Close{b.tab_id})
				ui_do(Set_Focus{""})
				app.key_taken = true
				return true
			}
		}
		if w == "browser_prompt" && page_prompt_tab == b.tab_id && p.dialog {
			#partial switch e.key_code {
			case .ENTER, .KP_ENTER:
				if !bars_click_ok(b.tab_id, time.tick_now()) {
					fmt.printfln("[browser] Enter in the prompt field ignored: the bars have just changed")
					app.key_taken = true
					return true
				}
				ui_do(Browser_Dialog{tab_id = b.tab_id, ok = true, text = tf_text(&page_prompt_field)})
				app.key_taken = true
				return true
			case .ESCAPE:
				ui_do(Browser_Dialog{tab_id = b.tab_id, ok = false})
				app.key_taken = true
				return true
			}
		}
	case .MOUSE_DOWN:
		page_pointer_in = false // a click hides the page's tooltip
		// what is over the bars takes the click: an overlay, Atlas's drawer (browser.odin's covered)
		if over_overlay() || (state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y)) do return false
		if e.mouse_button != .LEFT do return false
		// the tab's bars changed or came on screen just now: the click is ignored (bars_click_ok)
		if bar := pg_bar_at(e); bar != .None && !bars_click_ok(b.tab_id, time.tick_now()) {
			fmt.printfln("[browser] a click on the %s bar ignored: the bars have just changed", PG_BAR_NAMES[bar])
			app.redraw = true
			return true
		}
		took := true
		switch {
		case hit("pg_more", e):
			if d := clay.GetElementData(cid("pg_more")); d.found {
				bb := d.boundingBox
				menu_open(Menu_Browser{tab_id = b.tab_id, more = true}, {bb.x + bb.width - px(220), bb.y + bb.height + px(SP_1)})
			}
		case hit("pg_zoom", e):         ui_do(Browser_Zoom{b.tab_id, .Reset})
		case hit("pg_find_prev", e):    find_step(true)
		case hit("pg_find_next", e):    find_step(false)
		case hit("pg_find_close", e):   ui_do(Browser_Find_Close{b.tab_id})
		case hit("pg_find_box", e):
			if state.focus_widget != "browser_find" {
				page_find_tab = b.tab_id
				tf_set(&page_find_field, p.find_text)
				ui_do(Set_Focus{"browser_find"})
			}
			took = false // the field places its caret (widget_event)
		case hit("pg_dialog_ok", e):     ui_do(Browser_Dialog{tab_id = b.tab_id, ok = true, text = page_prompt_answer(b.tab_id, p)})
		case hit("pg_dialog_cancel", e): ui_do(Browser_Dialog{tab_id = b.tab_id, ok = false})
		case hit("pg_prompt_box", e):
			if page_prompt_tab != b.tab_id {
				// the shared field: this prompt's default, never another tab's text
				tf_set(&page_prompt_field, p.prompt_default)
				page_prompt_tab = b.tab_id
			}
			if state.focus_widget != "browser_prompt" do ui_do(Set_Focus{"browser_prompt"})
			took = false
		case hit("pg_perm_allow", e):  ui_do(Browser_Permission{tab_id = b.tab_id, allow = true})
		case hit("pg_perm_block", e):  ui_do(Browser_Permission{tab_id = b.tab_id, allow = false})
		case hit("pg_popup_open", e):  ui_do(Browser_Popup{tab_id = b.tab_id, open = true})
		case hit("pg_popup_close", e): ui_do(Browser_Popup{tab_id = b.tab_id, open = false})
		case hit("pg_dlask_allow", e): ui_do(Browser_Download{download_id = u64(p.ask_id), op = .Allow})
		case hit("pg_dlask_block", e): ui_do(Browser_Download{download_id = u64(p.ask_id), op = .Block})
		case hit("pg_crash_reload", e): ui_do(Browser_Reload{b.tab_id})
		case hit("pg_upload_allow", e): ui_do(Browser_Upload_Answer{tab_id = b.tab_id, allow = true}) // browser_act.odin
		case hit("pg_upload_block", e): ui_do(Browser_Upload_Answer{tab_id = b.tab_id, allow = false})
		case hit("pg_dl_open", e), hit("pg_dl_reveal", e), hit("pg_dl_cancel", e), hit("pg_dl_close", e):
			if d := page_bar_download(b.tab_id); d != nil {
				op: Browser_Download_Op = hit("pg_dl_open", e) ? .Open : hit("pg_dl_reveal", e) ? .Reveal : hit("pg_dl_cancel", e) ? .Cancel : .Dismiss
				ui_do(Browser_Download{download_id = u64(d.id), op = op})
			}
		case: took = false
		}
		if took {
			app.redraw = true
			return true
		}
	case .MOUSE_MOVE:
		// the page's pointer shape and tooltip while the pointer is over it (the page gets the move)
		pane := pane_rect(pn)
		in_pg := pane.z > 0 && e.mouse_x >= pane.x && e.mouse_y >= pane.y && e.mouse_x < pane.x + pane.z && e.mouse_y < pane.y + pane.w
		in_pg = in_pg && !over_overlay() && !(state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y))
		if in_pg != page_pointer_in || (in_pg && p.tooltip != "") do app.redraw = true
		if in_pg && page_pointer_tab != b.tab_id do app.redraw = true // another pane's page
		page_pointer_in, page_pointer = in_pg, {e.mouse_x, e.mouse_y}
		page_pointer_tab = in_pg ? b.tab_id : 0
		if in_pg && b.cef != 0 && !annot_on(b) && sapp.get_mouse_cursor() != p.cursor do sapp.set_mouse_cursor(p.cursor)
	case .MOUSE_LEAVE:
		page_pointer_in = false
	}
	return false
}

// The download whose bar the tab shows: its newest one not dismissed.
page_bar_download :: proc(tab_id: u64) -> ^Page_Download {
	#reverse for &d in page_downloads do if d.tab_id == tab_id && !d.dismissed do return &d
	return nil
}

// ---- drawing ----

@(private = "file")
pg_button :: proc(id: clay.ElementId, label: string, primary := false) {
	th := theme()
	hovered := clay.PointerOver(id)
	bg := primary ? th.accent : mix(th.bg_elevated, th.text, hovered ? TINT_BUTTON_HOVER : TINT_BUTTON)
	if clay.UI(id)({
		layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_3), pu(SP_3), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(bg),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_MD)),
	}) {
		clay.TextDynamic(label, txt(primary ? th.text_on_accent : th.text, primary ? WEIGHT_BOLD : WEIGHT_REGULAR))
	}
}

@(private = "file")
pg_field :: proc(box, text_id: clay.ElementId, f: ^Text_Field, placeholder: string, focused: bool, width: f32) {
	th := theme()
	if clay.UI(box)({
		layout = {sizing = {clay.SizingFixed(px(width)), clay.SizingFixed(px(BUTTON_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_field),
		cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
		border = {color = cc(focused ? th.accent : th.border), width = {pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), pu(FOCUS_RING_W), 0}},
	}) {
		shown, _, _ := tf_display(f, focused ? ime.marked : "")
		if clay.UI(text_id)({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
			if shown == "" && !focused do clay.TextDynamic(placeholder, txt(th.text_muted))
			else do clay.TextDynamic(shown, txt(th.text))
		}
	}
}

// One bar under the toolbar (a dot, the text clipped to what is left, then its buttons): its
// element's config (clay.UI must be called where the children are, not in a helper).
@(private = "file")
pg_bar :: proc() -> clay.ElementDeclaration {
	th := theme()
	return {
		layout = {sizing = {clay.SizingGrow(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}
}

// The room a bar's text has: the bar's width less what its buttons take.
@(private = "file")
pg_room :: proc(reserve: f32) -> f32 {
	room := px(300)
	if d := clay.GetElementData(cid("browser_bar")); d.found do room = max(d.boundingBox.width - reserve, px(80))
	return room
}

@(private = "file")
pg_text :: proc(id: clay.ElementId, s: string, col: Rgba, reserve: f32) {
	if clay.UI(id)({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
		clay.TextDynamic(clip(one_line(s, context.temp_allocator), pg_room(reserve)), txt(col))
	}
}

// "<origin> wants to …": the origin clipped from the left (the end of the host stays: the part
// that names the site), the phrase always whole.
@(private = "file")
pg_wants_text :: proc(id: clay.ElementId, origin, phrase: string, col: Rgba, reserve: f32) {
	measure :: proc(s: string) -> f32 {return text_w(s)}
	ph := one_line(phrase, context.temp_allocator)
	o := clip_left_by(one_line(url_origin(origin), context.temp_allocator), pg_room(reserve) - text_w(ph), measure)
	if clay.UI(id)({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
		clay.TextDynamic(strings.concatenate({o, ph}, context.temp_allocator), txt(col))
	}
}

@(private = "file")
pg_grow :: proc() {
	if clay.UI()({layout = {sizing = {clay.SizingGrow(), clay.SizingFit()}}}) {}
}

// The zoom chip shows (the page is not at 100%).
browser_zoomed :: proc(b: ^Browser) -> bool {
	p := page_extras[b.tab_id]
	return p != nil && b.cef != 0 && abs(zoom_factor(p.zoom_level) - 1) > 0.001
}

// The toolbar's end (browser_nav.odin's browser_bar_layout): the zoom chip (not at 100%) and ⋯.
browser_polish_toolbar_layout :: proc(b: ^Browser) {
	if browser_zoomed(b) do pg_button(cid("pg_zoom"), zoom_percent(page_extras[b.tab_id].zoom_level))
	pg_button(cid("pg_more"), "⋯")
}

// The bars under the toolbar (browser_nav.odin's browser_bar_layout, after the toolbar), and the
// page's tooltip.
browser_polish_bars_layout :: proc(b: ^Browser) {
	th := theme()
	_, tab, _ := find_tab(b.tab_id)
	if tab == nil do return
	bt, _ := tab.kind.(Browser_Tab)
	p := page_extras[b.tab_id]
	if p != nil && p.crashed {
		if clay.UI(cid("pg_crash"))(pg_bar()) {
			dot(th.error)
			pg_text(cid("pg_crash_text"), "This page crashed", th.text, px(200))
			pg_grow()
			pg_button(cid("pg_crash_reload"), "Reload", true)
		}
	}
	if p != nil && p.dialog {
		if clay.UI(cid("pg_dialog"))(pg_bar()) {
			dot(th.waiting)
			leave := p.dialog_kind == .Leave || p.dialog_kind == .Leave_Reload
			reserve := px(p.dialog_kind == .Prompt ? 560 : 260)
			pg_text(cid("pg_dialog_text"), dialog_bar_text(p.dialog_kind, p.dialog_msg, p.dialog_origin, bt.url), th.text, reserve)
			if p.dialog_kind == .Prompt {
				// the shared answer field only when it is this tab's; else this prompt's default
				if page_prompt_tab == b.tab_id do pg_field(cid("pg_prompt_box"), cid("pg_prompt_text"), &page_prompt_field, "Answer", state.focus_widget == "browser_prompt", 240)
				else {
					f: Text_Field
					tf_set(&f, p.prompt_default)
					pg_field(cid("pg_prompt_box"), cid("pg_prompt_text_idle"), &f, "Answer", false, 240)
					delete(f.buf)
				}
			}
			pg_grow()
			if p.dialog_kind != .Alert do pg_button(cid("pg_dialog_cancel"), leave ? "Stay" : "Cancel")
			pg_button(cid("pg_dialog_ok"), leave ? (p.dialog_kind == .Leave_Reload ? "Reload" : "Leave") : "OK", true)
		}
	}
	if p != nil && p.perm != 0 {
		if clay.UI(cid("pg_perm"))(pg_bar()) {
			dot(th.waiting)
			pg_wants_text(cid("pg_perm_text"), p.perm_origin, fmt.tprintf(" wants to %s", perm_phrase(p.perm)), th.text, px(260))
			pg_grow()
			pg_button(cid("pg_perm_block"), "Block")
			pg_button(cid("pg_perm_allow"), "Allow", true)
		}
	}
	if p != nil && p.ask_id != 0 {
		if clay.UI(cid("pg_dlask"))(pg_bar()) {
			dot(th.waiting)
			measure :: proc(s: string) -> f32 {return text_w(s)}
			line := ask_bar_text(one_line(url_origin(bt.url), context.temp_allocator), one_line(p.ask_name, context.temp_allocator), pg_room(px(260)), px(140), measure)
			if clay.UI(cid("pg_dlask_text"))({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
				clay.TextDynamic(line, txt(th.text))
			}
			pg_grow()
			pg_button(cid("pg_dlask_block"), "Block")
			pg_button(cid("pg_dlask_allow"), "Allow", true)
		}
	}
	// an agent asks to upload files (browser_act.odin): who, which files (names), to which site
	if who, names, asking := browser_act_upload_words(b.tab_id); asking {
		if clay.UI(cid("pg_upload"))(pg_bar()) {
			dot(th.waiting)
			measure :: proc(s: string) -> f32 {return text_w(s)}
			// the origin clipped from the left (its end names the site), who at most 30 %, the
			// files' names in the middle of what is left; the phrases always whole
			room := pg_room(px(260))
			origin := clip_left_by(one_line(url_origin(bt.url), context.temp_allocator), room * 0.35, measure)
			asker := clip(one_line(who, context.temp_allocator), max(room * 0.3, px(60)))
			tail := fmt.tprintf(" to %s", origin)
			names_room := max(room - text_w(asker) - text_w(" wants to upload ") - text_w(tail), px(60))
			line := strings.concatenate({asker, " wants to upload ", clip_middle_keep_ext(one_line(names, context.temp_allocator), names_room, measure), tail}, context.temp_allocator)
			if clay.UI(cid("pg_upload_text"))({layout = {sizing = {clay.SizingFit(), clay.SizingFit()}}}) {
				clay.TextDynamic(line, txt(th.text))
			}
			pg_grow()
			pg_button(cid("pg_upload_block"), "Block")
			pg_button(cid("pg_upload_allow"), "Allow", true)
		}
	}
	if bt.blocked_popup != "" {
		if clay.UI(cid("pg_popup"))(pg_bar()) {
			dot(th.text_muted)
			n := p != nil ? p.popups_blocked : 1
			what := n > 1 ? fmt.tprintf("%d popups blocked", n) : "Popup blocked"
			pg_text(cid("pg_popup_text"), fmt.tprintf("%s: %s", what, browser_url_public(bt.blocked_popup)), th.text, px(260))
			pg_grow()
			pg_button(cid("pg_popup_close"), "×")
			pg_button(cid("pg_popup_open"), "Open", true)
		}
	}
	if d := page_bar_download(b.tab_id); d != nil {
		if clay.UI(cid("pg_dl"))(pg_bar()) {
			msg: string
			switch d.state {
			case .Going:
				msg = d.total > 0 ? fmt.tprintf("Downloading %s · %d%%", d.name, int(100 * d.received / max(d.total, 1))) : fmt.tprintf("Downloading %s · %s", d.name, size_text(d.received))
			case .Done:      msg = fmt.tprintf("Downloaded %s to %s", d.name, fs_display(filepath.dir(d.path)))
			case .Cancelled: msg = fmt.tprintf("Download cancelled: %s", d.name)
			case .Failed:    msg = fmt.tprintf("Download failed: %s", d.name)
			}
			dot(d.state == .Failed ? th.error : d.state == .Done ? th.accent : th.text_muted)
			pg_text(cid("pg_dl_text"), msg, th.text, px(360))
			pg_grow()
			if d.state == .Going do pg_button(cid("pg_dl_cancel"), "Cancel")
			if d.state == .Done {
				// Open only for a file macOS checks before it runs (download_open_check)
				openable := download_open_check(d) == ""
				pg_button(cid("pg_dl_reveal"), "Show in Finder", !openable)
				if openable do pg_button(cid("pg_dl_open"), "Open", true)
			}
			pg_button(cid("pg_dl_close"), "×")
		}
	}
	if p != nil && p.find_open {
		if clay.UI(cid("pg_find"))(pg_bar()) {
			focused := state.focus_widget == "browser_find" && page_find_tab == b.tab_id
			if focused do pg_field(cid("pg_find_box"), cid("pg_find_text"), &page_find_field, "Find in page", true, 260)
			else {
				f: Text_Field
				tf_set(&f, p.find_text)
				pg_field(cid("pg_find_box"), cid("pg_find_text_idle"), &f, "Find in page", false, 260)
				delete(f.buf)
			}
			count := p.find_text == "" ? "" : p.find_matches == 0 ? "No matches" : fmt.tprintf("%d of %d", p.find_active, p.find_matches)
			clay.TextDynamic(count, txt(th.text_muted))
			pg_grow()
			pg_button(cid("pg_find_prev"), "‹")
			pg_button(cid("pg_find_next"), "›")
			pg_button(cid("pg_find_close"), "×")
		}
	}
	// the page's tooltip (its title text) under the pointer
	if p != nil && p.tooltip != "" && page_pointer_in && page_pointer_tab == b.tab_id && b.cef != 0 && !annot_on(b) {
		w, h := f32(sapp.width()), f32(sapp.height())
		tw := text_w(p.tooltip, FONT_UI_SMALL) + px(2 * SP_2)
		tw = min(tw, w - px(2 * SP_1))
		x := clamp(page_pointer.x, px(SP_1), max(w - tw - px(SP_1), 0))
		y := page_pointer.y + px(TIP_OFFSET)
		if y + px(TIP_H) > h do y = page_pointer.y - px(TIP_OFFSET) - px(TIP_H)
		if clay.UI(clay.ID("pg_tooltip"))({
			layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(TIP_H))}, padding = {pu(SP_2), pu(SP_2), 0, 0}, childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_elevated),
			cornerRadius = clay.CornerRadiusAll(px(RADIUS_SM)),
			border = {color = cc(th.border), width = clay.BorderOutside(pu(BORDER_W))},
			floating = {attachTo = .Root, offset = {x, y}, zIndex = 30},
		}) {
			clay.TextDynamic(clip(p.tooltip, tw - px(2 * SP_2)), txt(th.text, FONT_UI_SMALL))
		}
	}
}

@(private = "file")
size_text :: proc(n: i64) -> string {
	switch {
	case n >= 1 << 20: return fmt.tprintf("%.1f MB", f64(n) / (1 << 20))
	case n >= 1 << 10: return fmt.tprintf("%d KB", n >> 10)
	}
	return fmt.tprintf("%d bytes", n)
}

// ---- test mode (autotest.odin) ----
//
//   page_rclick X Y            a right click at page X,Y (logical px) through pi-desk's event path
//   page_menu LABEL            click the open menu's row LABEL
//   page_crash                 the page's renderer dies (chrome://crash)
//   page_assert cursor NAME    the page's pointer shape (default, hand, ibeam, …)
//   page_assert tooltip TEXT   the page's tooltip ("-" = none)
//   page_assert menu LABELS    the open menu's rows, "|"-separated ("-" = none open)
//   page_assert revealed PATH  the last download shown in Finder
//   page_assert opened URL     the last address opened with the default app (test mode: logged)
//   page_assert file SIZE PATH a file of SIZE bytes is at PATH ($datadir… are expanded)

page_script :: proc(cmd: string, args_raw: []string, rest: string) -> (msg: string, ok: bool) {
	args := strings.fields(rest, context.temp_allocator) // rest has $datadir… expanded
	b := tab_browser()
	switch cmd {
	case "page_rclick":
		if b == nil do return "page_rclick: no browser tab on screen", false
		if len(args) < 2 do return "page_rclick X Y", false
		x, _ := strconv.parse_f64(args[0])
		y, _ := strconv.parse_f64(args[1])
		r := tab_rect(b.tab_id)
		mx, my := r.x + f32(x) * app.dpi, r.y + f32(y) * app.dpi
		app.clicks = 1
		e := sapp.Event{type = .MOUSE_MOVE, mouse_x = mx, mouse_y = my}
		event(&e)
		e = {type = .MOUSE_DOWN, mouse_button = .RIGHT, mouse_x = mx, mouse_y = my}
		event(&e)
		e = {type = .MOUSE_UP, mouse_button = .RIGHT, mouse_x = mx, mouse_y = my}
		event(&e)
		return "", true
	case "page_menu":
		if !menu.open do return "page_menu: no menu is open", false
		for it, i in menu_items() {
			if it.label != rest || it.sep || it.note do continue
			d := clay.GetElementData(clay.ID("menurow", u32(i)))
			if !d.found do return fmt.tprintf("page_menu: row %q is not drawn yet", rest), false
			bb := d.boundingBox
			e := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = bb.x + bb.width / 2, mouse_y = bb.y + bb.height / 2}
			event(&e)
			e.type = .MOUSE_UP
			event(&e)
			return "", true
		}
		return fmt.tprintf("page_menu: no row %q", rest), false
	case "page_crash":
		if b == nil || b.cef == 0 do return "page_crash: no page", false
		pd_cef_test_crash(b.cef)
		return "", true
	case "page_assert":
		if len(args) < 1 do return "page_assert cursor|tooltip|menu|revealed|file …", false
		want := strings.trim_space(rest[len(args[0]):])
		got: string
		switch args[0] {
		case "cursor":
			if b == nil do return "page_assert: no browser tab on screen", false
			p := page_extra(b.tab_id)
			got = strings.to_lower(fmt.tprint(p.cursor), context.temp_allocator)
			if got == "pointing_hand" do got = "hand"
		case "tooltip":
			if b == nil do return "page_assert: no browser tab on screen", false
			p := page_extra(b.tab_id)
			got = p.tooltip != "" ? p.tooltip : "-"
		case "menu":
			if !menu.open do got = "-"
			else {
				labels := make([dynamic]string, context.temp_allocator)
				for it in menu_items() do append(&labels, it.sep ? "--" : it.label)
				got = strings.join(labels[:], "|", context.temp_allocator)
			}
		case "revealed":
			got = page_revealed
		case "file":
			// page_assert file SIZE PATH (the path may have spaces)
			if len(args) < 3 do return "page_assert file SIZE PATH", false
			path := strings.trim_space(want[len(args[1]):])
			fi, err := os.stat(path, context.temp_allocator)
			got = err == nil ? fmt.tprintf("%d %s", fi.size, path) : fmt.tprintf("missing %s", path)
			want = fmt.tprintf("%s %s", args[1], path)
		case "opened":
			got = autotest.opened_url
		case: return fmt.tprintf("page_assert: unknown %s", args[0]), false
		}
		if got != want do return fmt.tprintf("ASSERT FAILED page_assert %s: got %q, want %q", args[0], got, want), false
		fmt.printfln("[browser] assert ok: %s = %s", args[0], got)
		return "", true
	}
	return fmt.tprintf("unknown command %s", cmd), false
}
