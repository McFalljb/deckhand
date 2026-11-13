package core

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import jg "../jsonguard"

// From src/app_tab.odin (scripts/core-move.py): the core uses these, the window keeps
// the rest of that file.

App_Status :: enum {
	Starting,
	Running,
	Stalled, // no frame for APP_STALL_AFTER, but it answers tab.ping
	Not_Responding, // no answer to tab.ping, or a Mach send timed out
	Exited,
}

App_Tab :: struct {
	argv:       []string, // owned
	cwd:        string, // owned
	app_status: App_Status,
	exit_code:  int, // the last exit (-1 = none yet; 128+N for a signal)
}

// Commands (rows in command_table.odin).
New_App_Tab :: struct {
	session: u64, // 0 = the one on screen (a pi or Claude tab: its own)
	name:    string, // an app the session's .deckhand/apps.json declares (a pi or Claude tab: only this), or
	argv:    []string, // what to run (argv[0] on PATH), or
	command: string, // a command line for /bin/sh -c
	cwd:     string, // inside the session's folder ("" = it)
	title:   string,
}

App_Restart :: struct {
	tab_id: u64,
}

// Close an app tab: close_tab for an app tab, which a session's own agents may send too.
App_Close :: struct {
	tab_id:   u64,
	confirm:  string, // the user's close rule may ask (close_needs_confirm)
	comments: Comments_Choice, // pending comments made on it: send or drop (as close_tab)
}

// The apps a session's .deckhand/apps.json declares (what new_app_tab's name opens).
App_Declared :: struct {
	session: u64, // 0 = the caller's own (the user and scripts: the one on screen)
}

App_Input :: struct {
	tab_id: u64,
	events: []string, // JSON objects (TAB-PROTOCOL `input` without type/v), sent with "source":"agent"
}

App_Events :: struct {
	tab_id: u64,
	topic:  string, // "log" for tab.log events, ...
	since:  u64, // events after this seq
	limit:  int,
}

// Any method of the app's own (tab.describe lists them), passed through.
App_Call :: struct {
	tab_id:     u64,
	method:     string, // the request's `type` on the app's line
	params:     string, // a JSON object ("" = none): its fields go on the line as given
	timeout_ms: int,
}

// The frame on show (the slot Deckhand holds), as a PNG under the data dir.
App_Screenshot :: struct {
	tab_id:   u64,
	rect:     App_Rect, // the tab's logical px
	has_rect: bool, // false: the whole frame
}

// Draw the app's boxes (tab.boxes) over the tab; hovering shows a box's label.
App_Inspect :: struct {
	tab_id: u64,
	on:     bool,
}

App_Rect :: struct {
	x, y, w, h: f32,
}

// One of the app's boxes (tab.boxes): logical tab px.
App_Box :: struct {
	id, label: string,
	rect:      App_Rect,
}

// Internal: the app answered a request Deckhand sent it.
App_Call_Done :: struct {
	tab_id: u64,
	wire:   string, // our request id on the app's connection
	ok:     bool,
	error:  string,
	code:   string,
	data:   string, // JSON
	from_worker: bool, // a screenshot worker's, not the app's (only it may finish an "s…" wire)
	file:   string, // the worker's PNG: deleted if its request is gone
}

// Internal: the app's status changed (the frame loop saw it).
App_Update :: struct {
	tab_id:    u64,
	status:    App_Status,
	exit_code: int,
}

APP_EVENTS_MAX :: 500

APP_EVENT_TOPICS :: 32 // topics kept per tab

APP_METHOD_MAX :: 64 // app_call's method: [A-Za-z][A-Za-z0-9_.:/-]*

APP_BOXES_MAX :: 256 // tab.boxes kept per tab

APP_BOX_LABEL_MAX :: 200 // bytes of a box's label (id: APP_METHOD_MAX)

// ---- what the core reads for app tabs (moved from src/app_tab.odin, M3-G) ----

// An agent's app tab title: one line of at most this many characters.
APP_TITLE_MAX :: 80
// apps.json is read only up to this size.
APP_JSON_MAX :: 256 * 1024

// Apps listed in the session's .deckhand/apps.json ({"apps":[{"name","argv","cwd"?}]}).
App_Entry :: struct {
	name: string,
	argv: []string,
	cwd:  string,
}

// The project file: <cwd>/.deckhand/apps.json, else its name before the rename (0.2.0),
// <cwd>/.pi-desk/apps.json, read for good (it is committed in the user's repos; never moved).
// Both there: .deckhand/ only. Temp-allocated.
app_json_path :: proc(cwd: string) -> string {
	path, _ := filepath.join({cwd, ".deckhand", "apps.json"}, context.temp_allocator)
	if os.exists(path) do return path
	old, _ := filepath.join({cwd, ".pi-desk", "apps.json"}, context.temp_allocator)
	return os.exists(old) ? old : path
}

app_entries :: proc(cwd: string) -> []App_Entry {
	data, ok := app_json_read(app_json_path(cwd))
	if !ok do return nil
	v, perr := jg.parse(data, .JSON, true, context.temp_allocator)
	if perr != nil do return nil
	root, _ := v.(json.Object) // another shape lists nothing (an agent may have written the file)
	list, _ := root["apps"].(json.Array)
	out := make([dynamic]App_Entry, context.temp_allocator)
	for x in list {
		o, _ := x.(json.Object)
		name, _ := o["name"].(json.String)
		av, _ := o["argv"].(json.Array)
		cw, _ := o["cwd"].(json.String)
		if name == "" || strings.rune_count(name) > APP_TITLE_MAX || len(av) == 0 do continue
		argv := make([]string, len(av), context.temp_allocator)
		for s, i in av do argv[i] = s.(json.String) or_else ""
		append(&out, App_Entry{name = name, argv = argv, cwd = cw})
	}
	return out[:]
}

// apps.json's bytes (temp): a regular file, not a symbolic link, at most APP_JSON_MAX bytes.
// Opened without following a link and without blocking (a FIFO), then checked on the open file
// (an agent may have written it); never more than APP_JSON_MAX+1 bytes read.
@(private = "file")
app_json_read :: proc(path: string) -> ([]u8, bool) {
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.CLOEXEC, .NOFOLLOW, .NONBLOCK})
	if fd < 0 do return nil, false
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) || st.st_size > APP_JSON_MAX do return nil, false
	buf := make([]u8, APP_JSON_MAX + 1, context.temp_allocator)
	n := 0
	for n < len(buf) {
		want: int = len(buf) - n
		got := posix.read(fd, raw_data(buf[n:]), uint(want))
		if got < 0 && posix.errno() == .EINTR do continue
		if got <= 0 do break
		n += int(got)
	}
	if n > APP_JSON_MAX do return nil, false // grew since fstat
	return buf[:n], true
}

// The entry of the session's apps.json named `name`.
app_entry :: proc(cwd, name: string) -> (App_Entry, bool) {
	for e in app_entries(cwd) do if e.name == name do return e, true
	return {}, false
}

// Why `name` cannot open: the names the session declares.
app_not_declared :: proc(cwd, name: string) -> string {
	names := make([dynamic]string, context.temp_allocator)
	for e in app_entries(cwd) do append(&names, fmt.tprintf("%q", e.name))
	file := strings.has_suffix(app_json_path(cwd), "/.pi-desk/apps.json") ? ".pi-desk/apps.json" : ".deckhand/apps.json" // the one read
	if len(names) == 0 do return fmt.tprintf("no app %q: the session's folder declares none (%s)", name, file)
	return fmt.tprintf("no app %q in the session's %s (declared: %s)", name, file, strings.join(names[:], ", ", context.temp_allocator))
}

// The session new_app_tab and app_declared act in: a pi or Claude tab's own, never another;
// else the one named, or the caller's (Home's and an unbound caller's: the one on screen).
app_session :: proc(caller: Caller, session: u64) -> (^Open_Session, string) {
	if caller.kind == .Panel {
		own := caller_session(caller)
		if own == nil do return nil, "the calling tab has no session"
		if session != 0 && session != own.id do return nil, "a pi or Claude tab opens and lists apps in its own session only"
		return own, ""
	}
	s := session != 0 ? find_session(session) : caller_session(caller)
	if s != nil && s.home && session == 0 do s = cur()
	if s == nil do return nil, "no open session to open the app in"
	return s, ""
}


// ---- a window in another process (a separate core): its app tabs' connections ----

// An app tab's program connects to the core's socket (caller `app`), while its process and frames
// are the window's. The window's part, over window.command (separate core only; in process the
// window calls socket.odin itself): mint the tab's single-use token (the old one and its
// connection go first; data: the child's environment as a JSON array of "K=V"), send one line
// to the program, or forget the tab's token and connection. Internal (WINDOW_COMMANDS), no event.
App_Socket_Op :: enum u8 {
	Mint,
	Send,
	Forget,
}

APP_SOCKET_OP_NAMES := [App_Socket_Op]string{.Mint = "mint", .Send = "send", .Forget = "forget"}

App_Socket :: struct {
	tab_id: u64,
	op:     App_Socket_Op,
	line:   string, // Send: one line for the program
}

app_socket_apply :: proc(c: App_Socket) -> Result {
	_, tab, _ := find_tab(c.tab_id)
	switch c.op {
	case .Mint:
		// (new_app_tab's tab has no record yet: it follows the window's answer)
		if c.tab_id == 0 do return fail("no tab")
		if tab != nil {
			if _, is := tab.kind.(App_Tab); !is do return fail("not an app tab")
		}
		socket_forget_tab(c.tab_id)
		b := strings.builder_make(context.temp_allocator)
		strings.write_byte(&b, '[')
		for e, i in socket_child_env({kind = .App, tab_id = c.tab_id}) {
			if i > 0 do strings.write_byte(&b, ',')
			json_quote(&b, e)
		}
		strings.write_byte(&b, ']')
		return {ok = true, data = strings.clone(strings.to_string(b))}
	case .Send:
		if !socket_app_send(c.tab_id, c.line) do return fail("the app is not connected")
		return {ok = true}
	case .Forget:
		socket_forget_tab(c.tab_id)
		return {ok = true}
	}
	return fail("unknown op")
}

// A window in another process draws an inspected app tab's boxes: they go to it when they change
// (window.request app_boxes, the tab.boxes line's shape). Each core tick, while one is attached
// over core.sock.
app_boxes_tick :: proc() {
	if !window_link_is_sock() || !sync.atomic_exchange(&boxes_dirty, false) do return
	for s in state.open_sessions do for t in s.tabs {
		if _, is := t.kind.(App_Tab); !is do continue
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"boxes":[`)
		sync.lock(&boxes_mu)
		for x, i in boxes[t.id] or_else nil {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, `{"id":`)
			json_quote(&b, x.id)
			strings.write_string(&b, `,"label":`)
			json_quote(&b, x.label)
			fmt.sbprintf(&b, `,"rect":{{"x":%v,"y":%v,"w":%v,"h":%v}}}}`, x.rect.x, x.rect.y, x.rect.w, x.rect.h)
		}
		sync.unlock(&boxes_mu)
		strings.write_string(&b, "]}")
		window_app_boxes(t.id, strings.to_string(b))
	}
}
