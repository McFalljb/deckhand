package main

// App tabs (docs/ENGINE-BRIDGE.md, step 1): a program pi-desk starts as a
// child of a session (no PTY, its own session and process group) that
// renders into a ring of IOSurfaces pi-desk owns (frames.odin,
// src/native/frames_macos.m) and speaks NDJSON on pi-desk's socket as caller
// `app` (socket.odin). pi-desk shows the ring's newest slot as the tab's
// texture, forwards input as `input` messages, and passes the app's own
// methods through (app_call: any method; tab.describe lists them; pi-desk
// keeps tab.quit and tab.visible). It answers app_screenshot itself from the
// slot it shows, and draws the app's tab.boxes while the tab's Inspect is on.
// A game engine is the target; tests use the fake app (tests/fake-app/).
//
// Life: Starting (spawned, no HELLO yet) -> Running (frames) -> Stalled (no
// frame for 2 s but tab.ping answers) / Not_Responding (no answer, or a Mach
// send timed out) -> Exited (the last frame stays, dimmed, with Restart and
// Log). Exit code 75 restarts by itself (three times in 30 s at most).
// Closing sends tab.quit, then SIGTERM to the group after 2 s, SIGKILL after 5 s.
//
// .pi-desk/apps.json: the palette's list, and what a session's own agents (pi
// and Claude tabs) may open, by name, in their own session (new_app_tab).
// Left out (later steps): saving app tabs in the workspace, the activity strip
// for agent input. Clicking an inspected box opens
// a comment on it for the session's pi (comments.odin, ui_comments.odin).

import "base:runtime"
import "core:c"
import "core:crypto"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"
import clay "../build/clay-odin"
import sapp "../vendor/sokol-odin/sokol/app"
import sg "../vendor/sokol-odin/sokol/gfx"
import sgl "../vendor/sokol-odin/sokol/gl"
import stbi "vendor:stb/image"

App_Status :: enum {
	Starting,
	Running,
	Stalled, // no frame for APP_STALL_AFTER, but it answers tab.ping
	Not_Responding, // no answer to tab.ping, or a Mach send timed out
	Exited,
}
APP_STATUS_NAMES := [App_Status]string {
	.Starting       = "starting",
	.Running        = "running",
	.Stalled        = "stalled",
	.Not_Responding = "not_responding",
	.Exited         = "exited",
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
	name:    string, // an app the session's .pi-desk/apps.json declares (a pi or Claude tab: only this), or
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
// The apps a session's .pi-desk/apps.json declares (what new_app_tab's name opens).
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
// The frame on show (the slot pi-desk holds), as a PNG under the data dir.
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
// Internal: the app answered a request pi-desk sent it.
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

APP_STALL_AFTER :: 2 * time.Second
APP_PING_TIMEOUT :: 1 * time.Second
APP_PING_AGAIN :: 3 * time.Second // while no frames come, a ping this often (it may hang later)
APP_CALL_TIMEOUT :: 10 * time.Second
APP_QUIT_TERM :: 2 * time.Second // close: tab.quit, then SIGTERM
APP_QUIT_KILL :: 5 * time.Second // then SIGKILL
APP_RESTART_WINDOW :: 30 * time.Second // exit 75 restarts at most 3 times in this
APP_LOG_LINES :: 2000
APP_EVENTS_MAX :: 500
APP_EVENT_TOPICS :: 32 // topics kept per tab
APP_EXIT_RESTART :: 75
APP_METHOD_MAX :: 64 // app_call's method: [A-Za-z][A-Za-z0-9_.:/-]*
APP_PARAMS_MAX :: 256 * 1024 // app_call's params, as JSON text
APP_BOXES_MAX :: 256 // tab.boxes kept per tab
APP_BOX_LABEL_MAX :: 200 // bytes of a box's label (id: APP_METHOD_MAX)
APP_SHOTS_KEPT :: 32 // screenshots kept per tab (older ones are deleted)
APP_SHOT_TIMEOUT :: 30 * time.Second
APP_SHOTS_IN_FLIGHT :: 4 // screenshots being encoded at once (each holds a frame copy)
APP_SHOT_TYPE :: "#screenshot" // a pending screenshot's type: never a method name (app_call_check)
// pi-desk's own requests and the envelope's message types: never from app_call
APP_RESERVED := [?]string{"tab.quit", "tab.visible", "hello", "result", "event", "input"}

// Runtime per app tab (outside State), keyed by tab id.
App_Proc :: struct {
	tab_id:      u64,
	pid:         posix.pid_t, // 0 = not running
	title:       string, // for the bar ("sandbox exited …")
	log_path:    string,
	ring:        Frame_Ring,
	connected:   bool, // HELLO accepted
	sock_seen:   bool, // its NDJSON connection was seen open
	stalled:     bool, // FRAMES_F_STALLED: a Mach send timed out
	ping_wire:   string, // a stall's tab.ping in flight
	ping_at:     time.Tick,
	ping_answered: bool,
	sent_visible: int, // -1 = not sent yet, else 0/1
	restarts:    [dynamic]time.Tick, // automatic restarts (exit 75)
	quit_at:     time.Tick, // closing: tab.quit sent at
	term_sent:   bool,
	closing:     bool,
	started_at:  time.Tick,
	// input
	focused:     bool, // the app has pi-desk's keyboard (focus sent)
	held:        [dynamic]sapp.Keycode, // keys pressed in the app, not released yet
	buttons:     bit_set[0 ..< 3], // sokol's LEFT, RIGHT, MIDDLE held in the app
	last_x:      f32, // the pointer's last tab position (logical px)
	last_y:      f32,
	inputs:      u64, // input messages sent
	out:         ^App_Out, // stdout/stderr: shared with the reader threads
	// inspect (tab.boxes drawn over the tab)
	inspect:     bool,
	hover:       int, // the box under the pointer while inspecting (-1 = none)
	hx, hy:      f32, // the pointer while inspecting (logical tab px)
	hin:         bool, // it is over the tab
	shots:       u64, // screenshots taken (their file names)
	session:     u64, // the session it was opened in
	by_agent:    bool, // a pi or Claude tab opened it (APP_AGENT_MAX)
	// a hidden tab draws on demand: its first frame, and one per app_screenshot (app_frames_tick)
	framed:      bool, // this process gave a frame pi-desk took
	shot_waits:  [dynamic]Shot_Wait,
}

// An app_screenshot of a hidden app tab, waiting for a frame newer than seq.
Shot_Wait :: struct {
	request_id: u64,
	rect:       App_Rect,
	has_rect:   bool,
	seq:        u64,
	deadline:   time.Tick,
}

// How long a hidden tab's screenshot waits for a fresh frame (then: the last one, or no_frame).
APP_PEEK_TIMEOUT :: 3 * time.Second

// App tabs a session's agents may have running at once (also while closing).
APP_AGENT_MAX :: 8

// An agent's app tab title: one line of at most this many characters.
APP_TITLE_MAX :: 80
// apps.json is read only up to this size.
APP_JSON_MAX :: 256 * 1024
// App tabs a session's agents opened that still run, closing ones included.
app_agent_running :: proc(session: u64) -> int {
	n := 0
	for _, a in apps do if a.by_agent && a.session == session && a.pid != 0 do n += 1
	for a in dying do if a.by_agent && a.session == session && a.pid != 0 do n += 1
	return n
}

// Whether the caller is a pi tab started read-only (chat_env: a chat under Chats: read-only);
// what it was started with, not today's setting.
pi_chat_readonly :: proc(caller: Caller) -> bool {
	if caller.kind != .Panel || caller.claude do return false
	_, tab, _ := find_tab(caller.tab_id)
	if tab == nil do return false
	pt, is := tab.kind.(Pi_Tab)
	return is && pt.readonly
}

// An app tab's output: the last APP_LOG_LINES lines and the log file.
// Shared by the tab and each process's reader thread (a reader may outlive
// a restart or the tab: a grandchild can hold the pipe); the last one out frees it.
App_Out :: struct {
	mu:      sync.Mutex,
	refs:    int,
	lines:   [dynamic]string,
	partial: strings.Builder,
	log_fd:  posix.FD,
}

@(private = "file")
out_unref :: proc(o: ^App_Out) {
	sync.lock(&o.mu)
	o.refs -= 1
	last := o.refs == 0
	sync.unlock(&o.mu)
	if !last do return
	if o.log_fd > 0 do posix.close(o.log_fd)
	for l in o.lines do delete(l)
	delete(o.lines)
	strings.builder_destroy(&o.partial)
	free(o)
}

@(private = "file")
Reader_Arg :: struct {
	out: ^App_Out,
	fd:  posix.FD,
}

apps: map[u64]^App_Proc
app_sampler: sg.Sampler
dying: [dynamic]^App_Proc // closed tabs whose process is still going
@(private = "file")
reap: [dynamic]posix.pid_t // SIGKILLed: waited for with WNOHANG, never blocking the frame loop
frames_ok: int // 0 = not tried, 1 = serving, -1 = failed (unit tests set it: no frame server)

// pi-desk's own requests to apps (wire id "a<N>") and agents' app_call.
App_Pending :: struct {
	tab_id:     u64,
	request_id: u64, // 0 = pi-desk's own (ping, visible, quit)
	type:       string,
	deadline:   time.Tick,
}
pending: map[string]App_Pending
@(private = "file")
next_wire: u64

// Events from apps (tab.log, ...), kept per tab and topic; written by the
// socket's reader threads, read by app_events.
@(private = "file")
App_Event_Row :: struct {
	seq:  u64,
	line: string,
}
@(private = "file")
events_mu: sync.Mutex
@(private = "file")
events: map[u64]map[string][dynamic]App_Event_Row
@(private = "file")
events_seq: u64

app_host := Tab_Host {
	display = .Texture,
	draw = proc(tab_id: u64, x, y, w, h: f32) {app_draw(tab_id, x, y, w, h)},
	texture = proc(tab_id: u64) -> u32 {
		a := apps[tab_id]
		if a == nil do return 0
		g := ring_gen(&a.ring, a.ring.shown_gen)
		return g != nil ? g.image[a.ring.shown_slot].id : 0
	},
}

app_of :: proc(tab_id: u64) -> ^App_Proc {return apps[tab_id] or_else nil}

// The app of the tab on screen, or nil.
tab_app :: proc() -> ^App_Proc {
	if tab := active_tab(); tab != nil do return app_of(tab.id)
	return nil
}

@(private = "file")
app_tab_of :: proc(id: u64) -> (^Open_Session, ^Tab, ^App_Tab) {
	s, tab, _ := find_tab(id)
	if tab == nil do return nil, nil, nil
	at, is := &tab.kind.(App_Tab)
	if !is do return nil, nil, nil
	return s, tab, at
}

// ---- commands ----

app_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	// a pi or Claude tab (panel) reaches only its own session's app tabs, as its browser tabs, and
	// opens apps only there (new_app_tab, app_declared: app_session)
	if caller.kind == .Panel {
		tab_id: u64
		#partial switch c in cmd {
		case New_App_Tab, App_Declared:
		case App_Restart:    tab_id = c.tab_id
		case App_Close:      tab_id = c.tab_id
		case App_Input:      tab_id = c.tab_id
		case App_Events:     tab_id = c.tab_id
		case App_Call:       tab_id = c.tab_id
		case App_Screenshot: tab_id = c.tab_id
		case:                return fail("not allowed for this caller"), false
		}
		if tab_id != 0 {
			ts, _, _ := find_tab(tab_id)
			own := caller_session(caller)
			if ts == nil || own == nil || ts != own do return fail("a pi or Claude tab reaches only its own session's app tabs"), false
		}
		// a read-only chat's pi (Chats: read-only, as chat_env starts it) reads apps but runs none
		#partial switch _ in cmd {
		case New_App_Tab, App_Restart, App_Close:
			if !caller.claude && pi_chat_readonly(caller) do return fail("a read-only chat's pi may read apps, not open, restart or close them (it was started under Chats: read-only)"), false
		}
	}
	#partial switch c in cmd {
	case New_App_Tab:
		s, serr := app_session(caller, c.session)
		if s == nil do return fail(serr), false
		if s.home do return fail("Home has only its pi tab"), false
		agent := caller.kind == .Panel
		by_agent := agent // behind the view, counted against APP_AGENT_MAX, its title cleaned
		argv: []string
		cwd_arg, title := c.cwd, c.title
		if c.name != "" {
			// what the project declares, as the palette's "New app tab…" runs it
			if len(c.argv) > 0 || c.command != "" do return fail("name, or argv or command: not both"), false
			if agent && c.cwd != "" do return fail("cwd comes from .pi-desk/apps.json for a pi or Claude tab"), false
			e, found := app_entry(s.cwd, c.name)
			if !found do return fail(app_not_declared(s.cwd, c.name)), false
			argv = e.argv
			if cwd_arg == "" do cwd_arg = e.cwd
			if title == "" do title = e.name
		} else if agent {
			// a session's own agent runs only what its project declares (apps.json: the agent's own
			// authority, as its shell; docs/ENGINE-BRIDGE.md, trust model)
			return fail("a pi or Claude tab opens only the apps its project declares in .pi-desk/apps.json, by name (app_declared lists them)"), false
		} else if len(c.argv) > 0 do argv = c.argv
		else if strings.trim_space(c.command) != "" do argv = []string{"/bin/sh", "-c", c.command}
		else do return fail("argv or command is needed"), false
		cwd := s.cwd
		if cwd_arg != "" {
			p := cwd_arg
			if !filepath.is_abs(p) do p, _ = filepath.join({s.cwd, p}, context.temp_allocator)
			p, _ = filepath.clean(p, context.temp_allocator)
			base := fs_real(s.cwd)
			rp := fs_real(p)
			if rp != base && !strings.has_prefix(rp, strings.concatenate({base, "/"}, context.temp_allocator)) do return fail("cwd must be inside the session's folder"), false
			if !os.is_dir(rp) do return fail("cwd is not a folder"), false
			cwd = rp
		}
		if title == "" {
			// the program's name (a command line's first word)
			prog := argv[0]
			if len(argv) > 2 && argv[0] == "/bin/sh" {
				words := strings.fields(argv[2], context.temp_allocator)
				prog = len(words) > 0 ? words[0] : "app"
			}
			title = filepath.base(prog)
		}
		if by_agent {
			// the agent's text (its title, or an apps.json name it may have written) in the chrome
			title = strings.trim_space(one_line(title, context.temp_allocator))
			if n := strings.rune_count(title); n > APP_TITLE_MAX {
				i, k := 0, 0
				for _, j in title {
					if k == APP_TITLE_MAX {
						i = j
						break
					}
					k += 1
				}
				title = title[:i]
			}
			if title == "" do title = "app"
			if running := app_agent_running(s.id); running >= APP_AGENT_MAX do return fail(fmt.tprintf("this session already has %d app tabs its agents opened running (or still closing): close one first (app_close)", running)), false
		}
		owned := make([]string, len(argv))
		for a, i in argv do owned[i] = strings.clone(a)
		tab := Tab{id = new_id(), kind = App_Tab{argv = owned, cwd = strings.clone(cwd), exit_code = -1}, title = strings.clone(title), status = .Running}
		pane_add_tab(s, tab)
		if !by_agent {
			// an agent's (a pi or Claude tab's) opens behind the user's view, as its browser tabs;
			// the user's, a script's and Home's come to the front
			session_show_tab(s, tab.id)
			focus_session(s.id, caller)
		}
		a := new(App_Proc)
		a.tab_id = tab.id
		a.title = strings.clone(title)
		a.sent_visible = -1
		a.hover = -1
		a.ring.shown_slot = -1
		a.session, a.by_agent = s.id, by_agent
		apps[tab.id] = a
		if !app_spawn(a, owned, cwd) {
			_, t, at := app_tab_of(tab.id)
			at.app_status = .Exited
			t.status = .Exited
			at.exit_code = 127
			return {ok = true, created_id = tab.id, data = `{"started":false}`}, true
		}
		return {ok = true, created_id = tab.id}, true
	case App_Restart:
		_, tab, at := app_tab_of(c.tab_id)
		if tab == nil do return fail("no such app tab"), false
		a := app_of(c.tab_id)
		if a == nil do return fail("no such app tab"), false
		// an agent starting an exited app again: one more running against its session's cap
		if caller.kind == .Panel && a.by_agent && a.pid == 0 && app_agent_running(a.session) >= APP_AGENT_MAX {
			return fail(fmt.tprintf("this session already has %d app tabs its agents opened running (or still closing): close one first (app_close)", app_agent_running(a.session))), false
		}
		if a.pid != 0 {
			// a hung app: its group goes first; its ring with it (the last frame stays)
			posix.killpg(a.pid, .SIGKILL)
			append(&reap, a.pid) // reaped from the frame loop; the new one starts now
			app_gone(a, 128 + int(posix.Signal.SIGKILL))
		}
		clear(&a.restarts) // the user's restart starts the exit-75 count over
		ok := app_spawn(a, at.argv, at.cwd)
		at.app_status = ok ? .Starting : .Exited
		tab.status = ok ? .Running : .Exited
		return {ok = ok, error = ok ? "" : "could not start the app"}, true
	case App_Close:
		// close_tab's close (its confirmation rule, comments, tab.quit then SIGTERM), for app tabs only
		if _, tab, _ := app_tab_of(c.tab_id); tab == nil do return fail("no such app tab"), false
		return close_tab_apply(Close_Tab{tab_id = c.tab_id, confirm = c.confirm, comments = c.comments}, caller, request_id)
	case App_Declared:
		s, serr := app_session(caller, c.session)
		if s == nil do return fail(serr), false
		b := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&b, `{{"session":%d,"apps":[`, s.id)
		for e, i in app_entries(s.cwd) {
			if i > 0 do strings.write_byte(&b, ',')
			strings.write_string(&b, `{"name":`)
			json_quote(&b, e.name)
			strings.write_string(&b, `,"argv":[`)
			for x, j in e.argv {
				if j > 0 do strings.write_byte(&b, ',')
				json_quote(&b, x)
			}
			strings.write_byte(&b, ']')
			if e.cwd != "" {
				strings.write_string(&b, `,"cwd":`)
				json_quote(&b, e.cwd)
			}
			strings.write_byte(&b, '}')
		}
		strings.write_string(&b, "]}")
		return {ok = true, data = strings.to_string(b)}, false
	case App_Input:
		_, tab, _ := app_tab_of(c.tab_id)
		if tab == nil do return fail("no such app tab"), false
		a := app_of(c.tab_id)
		n := 0
		for ev in c.events do if e := app_input_event_check(ev); e != "" do return fail(e), false
		for ev in c.events {
			// {"event":…} -> {"v":1,"type":"input","source":"agent",…}
			body := strings.trim_space(ev)[1:]
			line := fmt.tprintf(`{{"v":1,"type":"input","source":"agent",%s`, body)
			if strings.trim_space(body) == "}" do line = `{"v":1,"type":"input","source":"agent"}`
			if a != nil && socket_app_send(c.tab_id, line) {
				a.inputs += 1
				n += 1
			}
		}
		if n < len(c.events) do return fail("the app is not connected"), false
		return {ok = true, data = fmt.tprintf(`{{"sent":%d}}`, n)}, false
	case App_Events:
		_, tab, _ := app_tab_of(c.tab_id)
		if tab == nil do return fail("no such app tab"), false
		return {ok = true, data = app_events_json(c.tab_id, c.topic, c.since, c.limit)}, false
	case App_Call:
		_, tab, _ := app_tab_of(c.tab_id)
		if tab == nil do return fail("no such app tab"), false
		if e, code := app_call_check(c.method, c.params); e != "" do return {error = e, data = fmt.tprintf(`{{"code":%q}}`, code)}, false
		timeout := c.timeout_ms > 0 ? time.Duration(c.timeout_ms) * time.Millisecond : APP_CALL_TIMEOUT
		if !app_request(c.tab_id, request_id, c.method, c.params, timeout) do return {error = "the app is not connected", data = `{"code":"tab_gone"}`}, false
		return {ok = true, pending = true}, false
	case App_Screenshot:
		return app_screenshot(c, request_id), false
	case App_Inspect:
		_, tab, _ := app_tab_of(c.tab_id)
		a := app_of(c.tab_id)
		if tab == nil || a == nil do return fail("no such app tab"), false
		if a.inspect == c.on do return {ok = true}, false
		a.inspect = c.on
		a.hover = -1
		app.redraw = true
		return {ok = true}, true
	case App_Call_Done:
		p, has := pending[c.wire]
		// timed out already, or not ours: only the asked tab's reply counts, an
		// app's only for an app call, a screenshot worker's only for its screenshot
		if !has || p.tab_id != c.tab_id || c.from_worker != (p.type == APP_SHOT_TYPE) {
			if c.from_worker && c.file != "" do posix.unlink(strings.clone_to_cstring(c.file, context.temp_allocator)) // nobody wants it now
			return {ok = true}, false
		}
		key, _ := delete_key(&pending, c.wire)
		delete(key)
		defer delete(p.type)
		if p.request_id != 0 {
			// the app's reply as sent (app_result_of: an error's data holds its code)
			res := Result{ok = c.ok, error = c.error, data = c.data}
			if !c.ok && c.code != "" && (c.data == "" || c.data == "{}") {
				b := strings.builder_make(context.temp_allocator)
				strings.write_string(&b, `{"code":`)
				json_quote(&b, c.code)
				strings.write_byte(&b, '}')
				res.data = strings.to_string(b)
			}
			emit_event(Finished_Event{request_id = p.request_id, result = res})
			return {ok = true}, false
		}
		// pi-desk's own: a stall's ping answered
		if a := app_of(c.tab_id); a != nil && p.type == "tab.ping" && a.ping_wire == c.wire {
			a.ping_answered = true
			delete(a.ping_wire)
			a.ping_wire = ""
		}
		return {ok = true}, false
	case App_Update:
		_, tab, at := app_tab_of(c.tab_id)
		if tab == nil do return {ok = true}, false
		if at.app_status == c.status && (c.status != .Exited || at.exit_code == c.exit_code) do return {ok = true}, false
		at.app_status = c.status
		if c.status == .Exited {
			at.exit_code = c.exit_code
			tab.status = .Exited
		} else do tab.status = .Running
		return {ok = true}, true
	}
	return fail("not an app command"), false
}

// Whether app_call may pass this on: only the envelope is checked (the
// methods are the app's own, found with tab.describe). error "" = yes; else
// its code: bad_args, or reserved for pi-desk's own requests (tab.quit,
// tab.visible: lifecycle and visibility are pi-desk's) and the envelope's
// message types (an `input` would skip app_input's "source":"agent").
app_call_check :: proc(method, params: string) -> (error, code: string) {
	if method == "" || len(method) > APP_METHOD_MAX do return fmt.tprintf("method must be 1 to %d characters", APP_METHOD_MAX), "bad_args"
	for ch, i in transmute([]u8)method {
		letter := ch >= 'a' && ch <= 'z' || ch >= 'A' && ch <= 'Z'
		if i == 0 && !letter do return "method must start with a letter", "bad_args"
		if !letter && !(ch >= '0' && ch <= '9') && !strings.contains_rune("_.:/-", rune(ch)) do return "method may have letters, digits and _ . : / - only", "bad_args"
	}
	for r in APP_RESERVED do if strings.equal_fold(method, r) do return fmt.tprintf("%s is Deckhand's own, not passed to the app", method), "reserved"
	if len(params) > APP_PARAMS_MAX do return fmt.tprintf("params are over %d KB", APP_PARAMS_MAX / 1024), "bad_args"
	// sent verbatim: a raw CR or LF would end the app's line early (see app_line_ok)
	if strings.contains_any(params, "\r\n") do return "params cannot contain a raw line break (CR or LF)", "bad_args"
	if strings.trim_space(params) != "" {
		members, ok := json_members_raw(params)
		if !ok do return "params must be a JSON object", "bad_args"
		for m in members {
			if m.key == "id" || m.key == "v" || m.key == "type" do return fmt.tprintf("params cannot set %q (the envelope's)", m.key), "bad_args"
			if strings.contains_rune(m.key, 0) do return "params keys cannot contain NUL", "bad_args"
		}
	}
	return "", ""
}

// Why one of app_input's events cannot go to the app ("" if it can).
app_input_event_check :: proc(ev: string) -> string {
	v, err := json.parse_string(ev, .JSON, true, context.temp_allocator)
	obj, is := v.(json.Object)
	if err != nil || !is do return "each event must be a JSON object"
	if _, has := obj["event"].(json.String); !has do return "each event needs \"event\""
	for k in ([]string{"type", "v", "id", "source"}) do if k in obj do return fmt.tprintf("an event cannot set %q (Deckhand's envelope)", k)
	for k in obj do if strings.contains_rune(k, 0) do return "an event's keys cannot contain NUL"
	return ""
}

// The request line to the app: our id, the envelope's version, the method
// as `type`, then the params' fields as given.
app_call_line :: proc(wire, method, params: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"id":"%s","v":1,"type":`, wire)
	json_quote(&b, method)
	p := strings.trim_space(params)
	if len(p) >= 2 {
		body := strings.trim_space(p[1:len(p) - 1])
		if body != "" {
			strings.write_byte(&b, ',')
			strings.write_string(&b, body)
		}
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

// An app's answer, from its line as sent (socket.odin): data verbatim (no
// re-marshal); an error's code and its other fields (traceback, path…) go in data.
App_Result :: struct {
	id:    string,
	ok:    bool,
	error: string,
	code:  string,
	data:  string, // one JSON value
}

app_result_of :: proc(line: string) -> (r: App_Result, valid: bool) {
	if !json_valid(line) do return // strict: what is passed on as sent must be JSON
	top, ok := json_members_raw(strings.trim_space(line))
	if !ok do return
	res := ""
	for m in top {
		switch m.key {
		case "id":     r.id, _ = json_string_of(m.raw)
		case "result": res = m.raw
		}
	}
	members, rok := json_members_raw(res)
	if !rok do return
	r.data = "{}"
	for m in members {
		switch m.key {
		case "ok":    r.ok = m.raw == "true"
		case "error": r.error, _ = json_string_of(m.raw)
		case "code":  r.code, _ = json_string_of(m.raw)
		case "data":  r.data = m.raw
		}
	}
	if r.ok do return r, true
	// an error: everything but ok and error, in the app's order (code, traceback, data…)
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '{')
	n := 0
	for m in members {
		if m.key == "ok" || m.key == "error" do continue
		if n > 0 do strings.write_byte(&b, ',')
		json_quote(&b, m.key)
		strings.write_byte(&b, ':')
		strings.write_string(&b, m.raw)
		n += 1
	}
	strings.write_byte(&b, '}')
	r.data = strings.to_string(b)
	return r, true
}

// A JSON string literal's value (temp), or ok=false.
@(private = "file")
json_string_of :: proc(raw: string) -> (string, bool) {
	v, err := json.parse_string(raw, .JSON, true, context.temp_allocator)
	s, is := v.(json.String)
	return s, err == nil && is
}

// Sends a request to the app; its reply finishes request_id (0 = pi-desk's
// own). False when the app is not connected.
@(private = "file")
app_request :: proc(tab_id, request_id: u64, method, params: string, timeout: time.Duration) -> bool {
	next_wire += 1
	wire := fmt.tprintf("a%d", next_wire)
	if !socket_app_send(tab_id, app_call_line(wire, method, params)) do return false
	pending[strings.clone(wire)] = {tab_id = tab_id, request_id = request_id, type = strings.clone(method), deadline = time.tick_add(time.tick_now(), timeout)}
	return true
}

// pi-desk's own request (no caller waits): its wire id, "" if not sent.
@(private = "file")
app_own_request :: proc(tab_id: u64, method, params: string, timeout: time.Duration) -> string {
	if !app_request(tab_id, 0, method, params, timeout) do return ""
	return strings.clone(fmt.tprintf("a%d", next_wire))
}

// Requests of a tab that will get no answer: finished with tab_gone.
// shots=false: a screenshot being written goes on (its frame is copied
// already; only closing the tab ends it).
app_fail_pending :: proc(tab_id: u64, why, code: string, shots := true) {
	gone := make([dynamic]string, context.temp_allocator)
	for k, p in pending do if p.tab_id == tab_id && (shots || p.type != APP_SHOT_TYPE) do append(&gone, k)
	for k in gone {
		key, p := delete_key(&pending, k)
		if p.request_id != 0 do emit_event(Finished_Event{request_id = p.request_id, result = {error = why, data = fmt.tprintf(`{{"code":%q}}`, code)}})
		delete(key)
		delete(p.type)
	}
}

app_command_clone :: proc(cmd: Command, allocator := context.allocator) -> Command {
	s :: proc(x: string, a := context.allocator) -> string {return strings.clone(x, a)}
	ss :: proc(x: []string, a := context.allocator) -> []string {
		out := make([]string, len(x), a)
		for v, i in x do out[i] = strings.clone(v, a)
		return out
	}
	#partial switch c in cmd {
	case New_App_Tab:   return New_App_Tab{session = c.session, name = s(c.name, allocator), argv = ss(c.argv, allocator), command = s(c.command, allocator), cwd = s(c.cwd, allocator), title = s(c.title, allocator)}
	case App_Close:     return App_Close{tab_id = c.tab_id, confirm = s(c.confirm, allocator), comments = c.comments}
	case App_Input:     return App_Input{tab_id = c.tab_id, events = ss(c.events, allocator)}
	case App_Events:    return App_Events{tab_id = c.tab_id, topic = s(c.topic, allocator), since = c.since, limit = c.limit}
	case App_Call:      return App_Call{tab_id = c.tab_id, method = s(c.method, allocator), params = s(c.params, allocator), timeout_ms = c.timeout_ms}
	case App_Call_Done: return App_Call_Done{tab_id = c.tab_id, wire = s(c.wire, allocator), ok = c.ok, error = s(c.error, allocator), code = s(c.code, allocator), data = s(c.data, allocator), from_worker = c.from_worker, file = s(c.file, allocator)}
	}
	return cmd
}

app_command_free :: proc(cmd: Command, allocator := context.allocator) {
	ss :: proc(x: []string, a := context.allocator) {
		for v in x do delete(v, a)
		delete(x, a)
	}
	#partial switch c in cmd {
	case New_App_Tab:
		ss(c.argv, allocator)
		delete(c.name, allocator)
		delete(c.command, allocator)
		delete(c.cwd, allocator)
		delete(c.title, allocator)
	case App_Close:  delete(c.confirm, allocator)
	case App_Input:  ss(c.events, allocator)
	case App_Events: delete(c.topic, allocator)
	case App_Call:
		delete(c.method, allocator)
		delete(c.params, allocator)
	case App_Call_Done:
		delete(c.wire, allocator)
		delete(c.error, allocator)
		delete(c.code, allocator)
		delete(c.file, allocator)
		delete(c.data, allocator)
	}
}

// ---- process ----

when ODIN_OS == .Darwin {
	foreign import applib "system:System"
	@(default_calling_convention = "c")
	foreign applib {
		posix_spawn_file_actions_addchdir_np :: proc(fa: rawptr, path: cstring) -> posix.Errno ---
		posix_spawn_file_actions_addopen :: proc(fa: rawptr, fd: i32, path: cstring, oflag: i32, mode: u16) -> posix.Errno ---
	}
	POSIX_SPAWN_SETSID :: 0x0400
}

// Where app_screenshot writes its PNGs: <data dir>/apps/shots (build/test-data
// in test mode without one), absolute.
app_shots_dir :: proc(allocator := context.allocator) -> string {
	root := home_root != "" ? home_root : "build/test-data"
	cwd := ""
	if !filepath.is_abs(root) do cwd, _ = os.get_working_directory(context.temp_allocator)
	dir, _ := filepath.join({cwd, root, "apps", "shots"}, allocator)
	return dir
}

// The app's environment: pi-desk's minus PI_DESK_* and PI_KIT_*, plus its
// socket, a fresh single-use `app` token for this tab and PI_DESK_APP=1.
@(private = "file")
app_env :: proc(tab_id: u64) -> []string {
	env := child_base_env() // after "Refresh shell environment", the refreshed one (login_env.odin)
	out := make([dynamic]string, context.temp_allocator)
	for e in env do if !strings.has_prefix(e, "PI_DESK_") && !strings.has_prefix(e, "PI_KIT_") do append(&out, e)
	append(&out, ..socket_child_env({kind = .App, tab_id = tab_id}))
	append(&out, "PI_DESK_APP=1")
	return out[:]
}

// Starts (or restarts) the tab's process: its own session (so its process
// group and session are its own), stdin /dev/null, stdout and stderr into
// the log; a fresh channel key. Main thread.
app_spawn :: proc(a: ^App_Proc, argv: []string, cwd: string) -> bool {
	if frames_ok == 0 {
		frames_ok = pd_frames_serve_start(sg.mtl_device()) == 1 ? 1 : -1
		app_shots_prune(app_shots_dir(context.temp_allocator), 24 * time.Hour) // the first app tab of this run
	}
	a.connected, a.stalled, a.sock_seen, a.ping_answered = false, false, false, false
	a.framed = false
	delete(a.ping_wire)
	a.ping_wire = ""
	a.sent_visible = -1
	a.focused = false
	clear(&a.held)
	a.buttons = {}
	a.started_at = time.tick_now()
	a.ring.cur_gen = 0 // a new process: its ring comes after its HELLO; the last frame stays
	a.ring.want_w, a.ring.want_h = 0, 0
	socket_forget_tab(a.tab_id) // an old process's token and connection
	app_fail_pending(a.tab_id, "the app restarted", "tab_gone", shots = false)
	// the log: <data dir>/apps/<tab_id>.log
	if a.log_path == "" {
		root := home_root != "" ? home_root : "build/test-data"
		dir, _ := filepath.join({root, "apps"}, context.temp_allocator)
		os.make_directory_all(dir)
		a.log_path = fmt.aprintf("%s/%d.log", dir, a.tab_id)
	}
	if a.out == nil {
		a.out = new(App_Out)
		a.out.refs = 1
		a.out.log_fd = posix.open(strings.clone_to_cstring(a.log_path, context.temp_allocator), {.WRONLY, .CREAT, .APPEND, .CLOEXEC}, {.IRUSR, .IWUSR})
	}
	app_log_line(a, fmt.tprintf("[Deckhand] starting: %s", strings.join(argv, " ", context.temp_allocator)))
	c_argv := make([]cstring, len(argv) + 1, context.temp_allocator)
	for x, i in argv do c_argv[i] = strings.clone_to_cstring(x, context.temp_allocator)
	env := app_env(a.tab_id)
	c_env := make([]cstring, len(env) + 1, context.temp_allocator)
	for e, i in env do c_env[i] = strings.clone_to_cstring(e, context.temp_allocator)
	// the channel first: the hello reply carries its key; the process is set once spawned
	key: [32]u8
	crypto.rand_bytes(key[:])
	if frames_ok == 1 do pd_frames_chan_open(a.tab_id, &key[0], 0, 0)
	crypto.zero_explicit(&key, size_of(key))
	fds: [2]posix.FD
	if posix.pipe(&fds) != .OK do return false
	posix.fcntl(fds[0], .SETFD, i32(posix.FD_CLOEXEC))
	posix.fcntl(fds[1], .SETFD, i32(posix.FD_CLOEXEC)) // other spawns meanwhile must not inherit it (dup2 into 1 and 2 clears it there)
	attr, fa: [512]u8
	posix_spawnattr_init(&attr)
	defer posix_spawnattr_destroy(&attr)
	posix_spawnattr_setflags(&attr, i16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
	posix_spawn_file_actions_init(&fa)
	defer posix_spawn_file_actions_destroy(&fa)
	posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", i32(posix.O_RDONLY), 0)
	posix_spawn_file_actions_adddup2(&fa, i32(fds[1]), 1)
	posix_spawn_file_actions_adddup2(&fa, i32(fds[1]), 2)
	posix_spawn_file_actions_addchdir_np(&fa, strings.clone_to_cstring(cwd, context.temp_allocator))
	pid: posix.pid_t
	// argv[0] on PATH; the child's environment is env
	sync.rw_mutex_shared_lock(&fork_lock) // fork_lock, pty.odin
	err := posix.posix_spawnp(&pid, c_argv[0], &fa, &attr, raw_data(c_argv), raw_data(c_env))
	sync.rw_mutex_shared_unlock(&fork_lock)
	posix.close(fds[1])
	if err != .NONE {
		posix.close(fds[0])
		app_log_line(a, fmt.tprintf("[Deckhand] could not start %s (%v)", argv[0], err))
		socket_forget_tab(a.tab_id)
		return false
	}
	a.pid = pid
	if frames_ok == 1 do pd_frames_chan_set_proc(a.tab_id, c.int(pid), c.int(pid)) // its own session and group: both are pid
	sync.lock(&a.out.mu)
	a.out.refs += 1
	sync.unlock(&a.out.mu)
	if thread.create_and_start_with_poly_data(Reader_Arg{out = a.out, fd = fds[0]}, app_reader, self_cleanup = true) == nil {
		posix.close(fds[0])
		out_unref(a.out)
	}
	return true
}

// The output pipe's reader: lines into the ring and the log file.
@(private = "file")
app_reader :: proc(r: Reader_Arg) {
	o := r.out
	buf: [8192]u8
	for {
		n := posix.read(r.fd, &buf[0], len(buf))
		if n <= 0 do break
		sync.lock(&o.mu)
		if o.log_fd > 0 do posix.write(o.log_fd, &buf[0], uint(n))
		for b in buf[:n] {
			if b == '\n' {
				out_add(o, strings.to_string(o.partial))
				strings.builder_reset(&o.partial)
			} else if strings.builder_len(o.partial) < 4096 do strings.write_byte(&o.partial, b)
		}
		sync.unlock(&o.mu)
	}
	posix.close(r.fd)
	out_unref(o)
}

// One line into the ring (o.mu held).
@(private = "file")
out_add :: proc(o: ^App_Out, line: string) {
	append(&o.lines, strings.clone(line))
	if len(o.lines) > APP_LOG_LINES {
		delete(o.lines[0])
		ordered_remove(&o.lines, 0)
	}
}

// A line of pi-desk's own into the tab's log (and its ring).
@(private = "file")
app_log_line :: proc(a: ^App_Proc, line: string) {
	o := a.out
	if o == nil do return
	sync.lock(&o.mu)
	defer sync.unlock(&o.mu)
	if o.log_fd > 0 {
		l := strings.concatenate({line, "\n"}, context.temp_allocator)
		posix.write(o.log_fd, raw_data(l), uint(len(l)))
	}
	out_add(o, line)
}

// Whether the tab's log ring has a line containing text (tests).
app_log_has :: proc(a: ^App_Proc, text: string) -> bool {
	o := a.out
	if o == nil do return false
	sync.lock(&o.mu)
	defer sync.unlock(&o.mu)
	for l in o.lines do if strings.contains(l, text) do return true
	return false
}

@(private = "file")
exit_code_of :: proc(st: c.int) -> int {
	if posix.WIFEXITED(st) do return int(posix.WEXITSTATUS(st))
	if posix.WIFSIGNALED(st) do return 128 + int(posix.WTERMSIG(st))
	return -1
}

// The process is gone: the channel stops, the shown slot stays (dimmed),
// the rest of the ring goes.
@(private = "file")
app_gone :: proc(a: ^App_Proc, code: int) {
	a.pid = 0
	a.connected = false
	if frames_ok == 1 do pd_frames_chan_stop(a.tab_id)
	socket_forget_tab(a.tab_id)
	app_fail_pending(a.tab_id, "the app exited", "tab_gone", shots = false)
	// hidden screenshots waiting for a frame: answered now (the last frame, or no_frame)
	for w in a.shot_waits {
		r := app_shot_now(a.tab_id, a, w.rect, w.has_rect, w.request_id)
		if !r.pending do emit_event(Finished_Event{request_id = w.request_id, result = r})
	}
	clear(&a.shot_waits)
	app_boxes_forget(a.tab_id) // its boxes went with it
	a.hover = -1
	delete(a.ping_wire)
	a.ping_wire = ""
	a.ring.cur_gen = 0
	app_free_rings(a, true)
	app_log_line(a, fmt.tprintf("[Deckhand] exited (code %d)", code))
}

// Frees the generations that may go (frames.odin's rule). app_gone: all
// but the shown slot.
@(private = "file")
app_free_rings :: proc(a: ^App_Proc, app_gone: bool) {
	gens := make([dynamic]u32, context.temp_allocator)
	ring_freeable(&a.ring, app_gone, &gens)
	for gen in gens do ring_free_gen(a, gen, -1)
	if app_gone && a.ring.shown_gen != 0 {
		// the dimmed last frame: its ring's other slots go
		if g := ring_gen(&a.ring, a.ring.shown_gen); g != nil && !g.freed {
			for s in 0 ..< FRAME_SLOTS do if s != a.ring.shown_slot && g.image[s].id != 0 {
				slot_destroy(g, s)
			}
			pd_frames_ring_free(a.tab_id, g.gen, c.int(a.ring.shown_slot))
			g.freed = true
		}
	}
}

@(private = "file")
ring_free_gen :: proc(a: ^App_Proc, gen: u32, keep: int) {
	for g, i in a.ring.gens {
		if g.gen != gen do continue
		for s in 0 ..< FRAME_SLOTS do slot_destroy(&a.ring.gens[i], s)
		pd_frames_ring_free(a.tab_id, gen, -1)
		ordered_remove(&a.ring.gens, i)
		return
	}
}

// sokol images wrapping app surfaces, alive (tests: every one is destroyed)
app_images: int

@(private = "file")
slot_destroy :: proc(g: ^Ring_Gen, s: int) {
	if g.image[s].id == 0 do return
	sg.destroy_view(g.view[s])
	sg.destroy_image(g.image[s])
	g.image[s], g.view[s] = {}, {}
	app_images -= 1
}

// A new ring at the pane's size (px) and scale; RING goes to the app.
@(private = "file")
app_ring_new :: proc(a: ^App_Proc, w, h: int, scale: f32) {
	gen := pd_frames_ring_new(a.tab_id, c.int(w), c.int(h), scale)
	if gen == 0 do return
	g := Ring_Gen{gen = gen, w = w, h = h, scale = scale}
	for s in 0 ..< FRAME_SLOTS {
		tex := pd_frames_slot_texture(a.tab_id, gen, c.int(s))
		g.image[s] = sg.make_image({width = c.int(w), height = c.int(h), pixel_format = .BGRA8, mtl_texture = tex})
		g.view[s] = sg.make_view({texture = {image = g.image[s]}})
		app_images += 1
	}
	append(&a.ring.gens, g)
	a.ring.cur_gen = gen
	app_log_line(a, fmt.tprintf("[Deckhand] ring %d: %dx%d px, scale %.2f", gen, w, h, scale))
}

// ---- the frame loop (main.odin) ----

// Every frame, before `if !app.redraw`: exits, what the Mach queue
// received, rings, stalls, visibility, closing tabs. True: redraw.
app_frames_tick :: proc() -> bool {
	if len(apps) == 0 && len(dying) == 0 && len(reap) == 0 do return false
	redraw := false
	if frames_ok == 1 && pd_frames_take_wake() != 0 do redraw = true // something arrived
	now := time.tick_now()
	// new boxes: an inspected tab on screen (any pane's) redraws, its hover follows them
	if sync.atomic_exchange(&boxes_dirty, false) {
		for id, a in apps do if a.inspect && tab_on_screen(id) {
			app_hover_at(a, a.hx, a.hy, a.hin)
			redraw = true
		}
	}
	for id, a in apps {
		_, tab, at := app_tab_of(id)
		if tab == nil do continue
		// the process
		if a.pid != 0 {
			st: c.int
			if r := posix.waitpid(a.pid, &st, {.NOHANG}); r == a.pid {
				code := exit_code_of(st)
				app_gone(a, code)
				redraw = true
				// 75: "restart me", at most 3 times in 30 s
				for len(a.restarts) > 0 && time.tick_diff(a.restarts[0], now) > APP_RESTART_WINDOW do ordered_remove(&a.restarts, 0)
				if code == APP_EXIT_RESTART && len(a.restarts) < 3 {
					append(&a.restarts, now)
					app_log_line(a, "[Deckhand] exit 75: restarting")
					if app_spawn(a, at.argv, at.cwd) {
						run_command(App_Update{tab_id = id, status = .Starting})
						continue
					}
				}
				run_command(App_Update{tab_id = id, status = .Exited, exit_code = code})
				continue
			}
		}
		if a.pid == 0 do continue
		// the socket: an app that hangs up is gone (its exit comes next)
		if socket_app_connected(id) do a.sock_seen = true
		else if a.sock_seen && !a.closing {
			a.sock_seen = false
			app_log_line(a, "[Deckhand] the app closed its connection: stopping it")
			posix.killpg(a.pid, .SIGTERM)
		}
		visible := tab_on_screen(id) // shown in any pane of the session on screen (panes.odin)
		// a hidden tab is told it shows until it gives its first frame and while a screenshot waits
		// for one (TAB-PROTOCOL: a tab told it is hidden draws nothing)
		peek := !visible && (!a.framed || len(a.shot_waits) > 0)
		told := visible || peek
		p: Frames_Poll
		if frames_ok == 1 do pd_frames_poll(id, &p) // cheap: one lock, a copy
		if p.flags & FRAMES_F_CONNECTED != 0 {
			a.connected = true
			app_log_line(a, "[Deckhand] frame channel connected")
		}
		if p.flags & FRAMES_F_REJECTED != 0 do app_log_line(a, "[Deckhand] a HELLO was refused (key or sender)")
		if p.flags & FRAMES_F_DEAD != 0 && a.connected {
			a.connected = false
			app_log_line(a, "[Deckhand] the frame channel died")
		}
		if p.flags & FRAMES_F_STALLED != 0 && !a.stalled {
			a.stalled = true
			app_log_line(a, "[Deckhand] a Mach send timed out: not responding")
		}
		if p.done_gen > a.ring.done_gen do a.ring.done_gen = p.done_gen
		// rings: the first one, and a new one when the pane's size settled
		if r := tab_rect(id); a.connected && !a.stalled && r.z > 0 {
			w, h := int(math.round(r.z)), int(math.round(r.w)) // its pane's size (panes.odin)
			if visible || a.ring.cur_gen == 0 { // a ring of its own pane's size
				if ring_wants_new(&a.ring, w, h, app.dpi, now) do app_ring_new(a, w, h, app.dpi)
			}
		}
		// a frame
		if p.has_frame != 0 {
			if told {
				og, os_, retire := ring_take(&a.ring, p.gen, p.slot, p.seq, p.tick)
				if retire do pd_frames_retire(id, og, u32(os_))
				a.ring.last_frame = now
				a.framed = true
				if visible {
					pd_frames_shown(id, p.recv_ms)
					redraw = true
				}
			} else {
				if ring_may_release_now(&a.ring, p.gen, p.slot) do pd_frames_release_now(id, p.gen, p.slot) // never drawn
				a.ring.last_frame = now
			}
		}
		app_free_rings(a, false)
		// hidden screenshots: a frame newer than the ask, or (late) the last one
		for i := 0; i < len(a.shot_waits); {
			w := a.shot_waits[i]
			if !visible && !(a.ring.shown_gen != 0 && a.ring.shown_seq > w.seq) && time.tick_diff(w.deadline, now) <= 0 {
				i += 1
				continue
			}
			ordered_remove(&a.shot_waits, i)
			r := app_shot_now(id, a, w.rect, w.has_rect, w.request_id)
			if !r.pending do emit_event(Finished_Event{request_id = w.request_id, result = r})
		}
		// visibility: tab.visible when it changes
		if a.sent_visible != int(told) && socket_app_connected(id) {
			if w := app_own_request(id, "tab.visible", fmt.tprintf(`{{"visible":%v}}`, told), APP_CALL_TIMEOUT); w != "" {
				delete(w)
				a.sent_visible = int(told)
				if visible do a.ring.last_frame = now // silence while hidden is no stall
			}
		}
		// stalls: no frame for 2 s while visible -> tab.ping (1 s)
		status := at.app_status
		want := status
		if a.stalled do want = .Not_Responding
		else if !a.connected do want = status == .Exited ? .Exited : .Starting
		else if visible && a.ring.last_frame != {} && time.tick_diff(a.ring.last_frame, now) > APP_STALL_AFTER {
			if app_should_ping(a.ping_wire != "", a.ping_answered, a.ping_at, now) {
				a.ping_wire = app_own_request(id, "tab.ping", "", APP_PING_TIMEOUT)
				a.ping_at = now
				a.ping_answered = false
			}
			want = app_stall_status(status, a.ping_wire != "", a.ping_answered, a.ping_at, now)
		} else if a.ring.shown > 0 || a.ring.last_frame != {} {
			want = .Running
			a.ping_at, a.ping_answered = {}, false
		}
		if want != status && status != .Exited {
			run_command(App_Update{tab_id = id, status = want})
			redraw = true
		}
		if want == .Stalled && visible && app_badge_changed(a, now) do redraw = true
	}
	// pi-desk's own requests that timed out
	if len(pending) > 0 {
		late := make([dynamic]string, context.temp_allocator)
		for k, p in pending do if time.tick_diff(p.deadline, now) > 0 do append(&late, k)
		for k in late {
			key, p := delete_key(&pending, k)
			if p.request_id != 0 do emit_event(Finished_Event{request_id = p.request_id, result = {error = "the app did not answer in time", data = `{"code":"timeout"}`}})
			if a := app_of(p.tab_id); a != nil && a.ping_wire == key {
				delete(a.ping_wire)
				a.ping_wire = ""
			}
			delete(key)
			delete(p.type)
		}
	}
	// closed tabs: tab.quit, SIGTERM after 2 s, SIGKILL after 5 s
	for i := len(dying) - 1; i >= 0; i -= 1 {
		a := dying[i]
		st: c.int
		done := a.pid == 0 || posix.waitpid(a.pid, &st, {.NOHANG}) == a.pid
		if !done && !a.term_sent && time.tick_diff(a.quit_at, now) > APP_QUIT_TERM {
			posix.killpg(a.pid, .SIGTERM)
			a.term_sent = true
		}
		if !done && time.tick_diff(a.quit_at, now) > APP_QUIT_KILL {
			posix.killpg(a.pid, .SIGKILL)
			append(&reap, a.pid)
			done = true
		}
		if done {
			app_proc_free(a)
			unordered_remove(&dying, i)
		}
	}
	for i := len(reap) - 1; i >= 0; i -= 1 {
		st: c.int
		r := posix.waitpid(reap[i], &st, {.NOHANG})
		for r == -1 && posix.errno() == .EINTR do r = posix.waitpid(reap[i], &st, {.NOHANG})
		if r == reap[i] || r == -1 && posix.errno() == .ECHILD do unordered_remove(&reap, i)
	}
	return redraw
}

// A visible app with no frames for APP_STALL_AFTER: whether to send a
// tab.ping now (none in flight), and what the tab's status becomes.
app_should_ping :: proc(in_flight, answered: bool, ping_at, now: time.Tick) -> bool {
	// answered or timed out: again APP_PING_AGAIN after the last one
	return !in_flight && (ping_at == {} || time.tick_diff(ping_at, now) > APP_PING_AGAIN)
}

app_stall_status :: proc(status: App_Status, in_flight, answered: bool, ping_at, now: time.Tick) -> App_Status {
	if answered || status == .Stalled && in_flight && time.tick_diff(ping_at, now) <= APP_PING_TIMEOUT do return .Stalled
	if ping_at != {} && time.tick_diff(ping_at, now) > APP_PING_TIMEOUT do return .Not_Responding
	return status
}

// The stall badge counts seconds: one redraw a second.
@(private = "file")
app_badge_changed :: proc(a: ^App_Proc, now: time.Tick) -> bool {
	@(static) last: int
	s := int(time.duration_seconds(time.tick_diff(a.ring.last_frame, now)))
	if s == last do return false
	last = s
	return true
}

// After sg.commit (main.odin): the retired slots' RELEASE after this frame's GPU work.
app_frames_committed :: proc() {
	if frames_ok == 1 do pd_frames_committed(sg.mtl_command_queue())
}

// The shown slot at the pane's top-left, 1:1 in px (clipped while a
// resize is on its way); dimmed once the app exited.
app_draw :: proc(tab_id: u64, x, y, w, h: f32) {
	a := app_of(tab_id)
	if a == nil || a.ring.shown_gen == 0 do return
	g := ring_gen(&a.ring, a.ring.shown_gen)
	if g == nil || g.image[a.ring.shown_slot].id == 0 do return
	if app_sampler.id == 0 do app_sampler = sg.make_sampler({min_filter = .NEAREST, mag_filter = .NEAREST})
	dw, dh := min(f32(g.w), w), min(f32(g.h), h)
	u, v := dw / f32(g.w), dh / f32(g.h)
	k: u8 = a.pid == 0 ? 110 : 255 // the last frame of an app that exited: dimmed
	sgl.end()
	sgl.texture(g.view[a.ring.shown_slot], app_sampler)
	sgl.begin_quads()
	sgl.v2f_t2f_c4b(x, y, 0, 0, k, k, k, 255)
	sgl.v2f_t2f_c4b(x + dw, y, u, 0, k, k, k, 255)
	sgl.v2f_t2f_c4b(x + dw, y + dh, u, v, k, k, k, 255)
	sgl.v2f_t2f_c4b(x, y + dh, 0, v, k, k, k, 255)
	sgl.end()
	sgl.texture(font.view, font.sampler)
	sgl.begin_quads()
	if a.inspect do app_draw_boxes(a, x, y, w, h)
}

// The tab closed (drop_term): tab.quit, then the process is stopped from
// the frame loop; its surfaces go now.
app_drop :: proc(tab_id: u64) {
	a := app_of(tab_id)
	if a == nil do return
	delete_key(&apps, tab_id)
	app_release_input(a)
	app_fail_pending(tab_id, "the tab closed", "tab_gone")
	for w in a.shot_waits do emit_event(Finished_Event{request_id = w.request_id, result = {error = "the tab closed", data = `{"code":"tab_gone"}`}})
	clear(&a.shot_waits)
	// the surfaces go now, whatever the process does; `a` is freed last
	for &g in a.ring.gens do for s in 0 ..< FRAME_SLOTS do slot_destroy(&g, s)
	clear(&a.ring.gens)
	a.ring.shown_gen, a.ring.cur_gen = 0, 0
	if frames_ok == 1 do pd_frames_chan_close(tab_id)
	if a.pid != 0 {
		w := app_own_request(tab_id, "tab.quit", "", APP_QUIT_KILL)
		delete(w)
		a.closing = true
		a.quit_at = time.tick_now()
		append(&dying, a)
	} else do app_proc_free(a)
	app_events_forget(tab_id)
	app_boxes_forget(tab_id)
}

app_event_topic_count :: proc(tab_id: u64) -> int {
	sync.lock(&events_mu)
	defer sync.unlock(&events_mu)
	return len(events[tab_id])
}

// A closed tab's events go.
app_events_forget :: proc(tab_id: u64) {
	sync.lock(&events_mu)
	defer sync.unlock(&events_mu)
	if m, ok := events[tab_id]; ok {
		for k, rows in m {
			for r in rows do delete(r.line)
			delete(rows)
			delete(k)
		}
		delete(m)
		delete_key(&events, tab_id)
	}
}

@(private = "file")
app_proc_free :: proc(a: ^App_Proc) {
	socket_forget_tab(a.tab_id)
	app_events_forget(a.tab_id) // a closing app's events after app_drop's forget
	app_boxes_forget(a.tab_id)
	if a.out != nil do out_unref(a.out)
	delete(a.restarts)
	delete(a.held)
	delete(a.ring.gens)
	delete(a.title)
	delete(a.log_path)
	delete(a.ping_wire)
	delete(a.shot_waits)
	free(a)
}

// Quit: every app's group gets SIGTERM, then SIGKILL (main.odin's cleanup).
app_shutdown :: proc() {
	pids := make([dynamic]posix.pid_t, context.temp_allocator)
	for _, a in apps do if a.pid != 0 do append(&pids, a.pid)
	for a in dying do if a.pid != 0 do append(&pids, a.pid)
	for p in reap do append(&pids, p)
	for p in pids do posix.killpg(p, .SIGTERM)
	deadline := time.tick_add(time.tick_now(), 300 * time.Millisecond)
	for p in pids {
		st: c.int
		for posix.waitpid(p, &st, {.NOHANG}) != p {
			if time.tick_diff(deadline, time.tick_now()) > 0 {
				posix.killpg(p, .SIGKILL)
				posix.waitpid(p, &st, {})
				break
			}
			time.sleep(5 * time.Millisecond)
		}
	}
}

// ---- events from the app (socket reader threads) ----

// One event line from an app ({"type":"event","event":"tab.log",…}), kept
// as sent: app_events pastes it into its reply, so it must be exactly one
// JSON object with nothing after it (json.parse_string ignores what follows;
// a re-marshal would change the app's numbers and keys).
app_event_in :: proc(tab_id: u64, event, line: string) {
	if event == "tab.boxes" {
		app_boxes_in(tab_id, line) // state, not history: replaces the last list, not kept as an event
		return
	}
	topic := strings.trim_prefix(event, "tab.")
	if topic == "" || len(topic) > 64 do return
	out := strings.trim_space(line)
	if !json_valid(out) do return // strict: it is passed on as sent
	{
		context.allocator = context.temp_allocator
		p := json.make_parser(out, .JSON, false, context.temp_allocator)
		v, err := json.parse_value(&p)
		if _, is := v.(json.Object); err != nil || !is || p.curr_token.kind != .EOF do return
	}
	sync.lock(&events_mu)
	defer sync.unlock(&events_mu)
	m := events[tab_id]
	if !(topic in m) && len(m) >= APP_EVENT_TOPICS do return // a flood of topic names
	rows := m[topic] if topic in m else nil
	events_seq += 1
	append(&rows, App_Event_Row{seq = events_seq, line = strings.clone(out)})
	if len(rows) > APP_EVENTS_MAX {
		delete(rows[0].line)
		ordered_remove(&rows, 0)
	}
	if topic in m do m[topic] = rows
	else do m[strings.clone(topic)] = rows
	events[tab_id] = m
}

app_events_json :: proc(tab_id: u64, topic: string, since: u64, limit: int) -> string {
	sync.lock(&events_mu)
	defer sync.unlock(&events_mu)
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"events":[`)
	n, last := 0, since
	lim := limit > 0 ? min(limit, APP_EVENTS_MAX) : 100
	if m, ok := events[tab_id]; ok do if rows, ok2 := m[topic]; ok2 {
		for r in rows {
			if r.seq <= since do continue
			if n >= lim do break
			if n > 0 do strings.write_byte(&b, ',')
			fmt.sbprintf(&b, `{{"seq":%d,"event":%s}}`, r.seq, r.line)
			last = r.seq
			n += 1
		}
	}
	fmt.sbprintf(&b, `],"next":%d}}`, last)
	return strings.to_string(b)
}

// ---- screenshots (app_screenshot) ----

// The crop in surface px: rect (logical tab px) times the ring's scale,
// clamped to the surface (sw x sh px); no rect = the whole frame. ok=false
// when nothing is left.
app_shot_rect :: proc(r: App_Rect, has: bool, scale: f32, sw, sh: int) -> (x, y, w, h: int, ok: bool) {
	if !has do return 0, 0, sw, sh, sw > 0 && sh > 0
	x0 := clamp(int(math.floor(r.x * scale)), 0, sw)
	y0 := clamp(int(math.floor(r.y * scale)), 0, sh)
	x1 := clamp(int(math.ceil((r.x + r.w) * scale)), 0, sw)
	y1 := clamp(int(math.ceil((r.y + r.h) * scale)), 0, sh)
	if r.w <= 0 || r.h <= 0 || x1 <= x0 || y1 <= y0 do return 0, 0, 0, 0, false
	return x0, y0, x1 - x0, y1 - y0, true
}

shots_running: int // atomic: screenshot workers alive

// Screenshots older than a day go (once, at the first app tab): an agent
// reads its file right after the reply; nothing keeps them.
app_shots_prune :: proc(dir: string, max_age: time.Duration) {
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	now := time.now()
	for fi in fis {
		if !strings.has_suffix(fi.name, ".png") && !strings.has_suffix(fi.name, ".png.tmp") do continue
		if time.diff(fi.modification_time, now) > max_age do os.remove(fi.fullpath)
	}
}

@(private = "file")
Shot_Job :: struct {
	tab_id:  u64,
	wire:    string, // owned
	path:    string, // owned
	old:     string, // owned: a screenshot to delete (APP_SHOTS_KEPT), "" = none
	pixels:  []u8, // BGRA, w*h*4, owned
	w, h:    int,
	meta:    string, // owned: the reply's other fields (seq, tick, scale, rect)
}

// Copies the frame on show (the slot pi-desk holds until a newer frame
// replaces it: never past its release) on the main thread, a memcpy of at
// most the frame; a worker encodes the PNG and finishes the request.
@(private = "file")
app_screenshot :: proc(cmd: App_Screenshot, request_id: u64) -> Result {
	_, tab, _ := app_tab_of(cmd.tab_id)
	a := app_of(cmd.tab_id)
	if tab == nil || a == nil do return fail("no such app tab")
	// hidden and running: it draws one frame for this (app_frames_tick), at most APP_PEEK_TIMEOUT
	if !tab_on_screen(cmd.tab_id) && a.pid != 0 && frames_ok == 1 && request_id != 0 {
		if len(a.shot_waits) >= APP_SHOTS_IN_FLIGHT do return {error = "screenshots are still being taken; try again", data = `{"code":"busy"}`}
		append(&a.shot_waits, Shot_Wait{request_id = request_id, rect = cmd.rect, has_rect = cmd.has_rect, seq = a.ring.shown_seq, deadline = time.tick_add(time.tick_now(), APP_PEEK_TIMEOUT)})
		return {ok = true, pending = true}
	}
	return app_shot_now(cmd.tab_id, a, cmd.rect, cmd.has_rect, request_id)
}

// app_screenshot of the frame pi-desk holds for the tab now.
app_shot_now :: proc(tab_id: u64, a: ^App_Proc, rect: App_Rect, has_rect: bool, request_id: u64) -> Result {
	cmd := App_Screenshot{tab_id = tab_id, rect = rect, has_rect = has_rect}
	g := ring_gen(&a.ring, a.ring.shown_gen)
	if a.ring.shown_gen == 0 || g == nil || frames_ok != 1 do return {error = "the app has shown no frame yet", data = `{"code":"no_frame"}`}
	x, y, w, h, ok := app_shot_rect(cmd.rect, cmd.has_rect, g.scale, g.w, g.h)
	if !ok do return {error = "the rect is outside the frame", data = `{"code":"bad_args"}`}
	a.shots += 1
	meta := fmt.tprintf(`"seq":%d,"tick":%d,"scale":%.2f,"rect":{{"x":%d,"y":%d,"w":%d,"h":%d}},"visible":%v`, a.ring.shown_seq, a.ring.shown_tick, g.scale, x, y, w, h, tab_on_screen(tab_id))
	return frame_shot(cmd.tab_id, g.gen, a.ring.shown_slot, x, y, w, h, a.shots, meta, request_id)
}

// A PNG of a ring slot's x,y,w×h px (the frame on show) under app_shots_dir as TAB-N.png,
// finishing request_id with {path, w, h, bytes, META}: the slot is copied here (main thread,
// a memcpy of at most the frame), a worker encodes and writes it. App tabs' app_screenshot and
// browser tabs' browser_screenshot (browser_agent.odin); N counts the tab's shots.
frame_shot :: proc(tab_id: u64, gen: u32, slot: int, x, y, w, h: int, n: u64, meta: string, request_id: u64) -> Result {
	// each one being written holds a copy of the frame (also after its request
	// timed out or its tab closed): a few at a time
	if sync.atomic_load(&shots_running) >= APP_SHOTS_IN_FLIGHT do return {error = "screenshots are still being written; try again", data = `{"code":"busy"}`}
	pixels := make([]u8, w * h * 4, runtime.heap_allocator())
	if pd_frames_read(tab_id, gen, c.int(slot), c.int(x), c.int(y), c.int(w), c.int(h), raw_data(pixels)) == 0 {
		delete(pixels, runtime.heap_allocator())
		return {error = "the frame could not be read", data = `{"code":"no_frame"}`}
	}
	dir := app_shots_dir(context.temp_allocator)
	os.make_directory_all(dir)
	next_wire += 1
	wire := fmt.tprintf("s%d", next_wire)
	ha := runtime.heap_allocator()
	job := new(Shot_Job, ha)
	job^ = {
		tab_id = tab_id,
		wire   = strings.clone(wire, ha),
		path   = fmt.aprintf("%s/%d-%d.png", dir, tab_id, n, allocator = ha),
		pixels = pixels,
		w      = w,
		h      = h,
		meta   = strings.clone(meta, ha),
	}
	if n > APP_SHOTS_KEPT do job.old = fmt.aprintf("%s/%d-%d.png", dir, tab_id, n - APP_SHOTS_KEPT, allocator = ha)
	pending[strings.clone(wire)] = {tab_id = tab_id, request_id = request_id, type = strings.clone(APP_SHOT_TYPE), deadline = time.tick_add(time.tick_now(), APP_SHOT_TIMEOUT)}
	sync.atomic_add(&shots_running, 1)
	if thread.create_and_start_with_poly_data(job, shot_write, self_cleanup = true) == nil {
		sync.atomic_sub(&shots_running, 1)
		shot_job_free(job)
		key, p := delete_key(&pending, wire)
		delete(key)
		delete(p.type)
		return fail("could not start the screenshot writer")
	}
	return {ok = true, pending = true}
}

@(private = "file")
shot_job_free :: proc(j: ^Shot_Job) {
	ha := runtime.heap_allocator()
	delete(j.wire, ha)
	delete(j.path, ha)
	delete(j.old, ha)
	delete(j.pixels, ha)
	delete(j.meta, ha)
	free(j, ha)
}

// The worker: BGRA -> RGBA, PNG into the file (0600, written whole then
// renamed), then app_call_done finishes the request on the main thread.
@(private = "file")
shot_write :: proc(j: ^Shot_Job) {
	context.allocator = runtime.heap_allocator()
	defer shot_job_free(j)
	defer free_all(context.temp_allocator)
	p := j.pixels
	for i := 0; i + 3 < len(p); i += 4 do p[i], p[i + 2] = p[i + 2], p[i]
	png := make([dynamic]u8, 0, len(p) / 4, context.allocator)
	defer delete(png)
	sink :: proc "c" (ctx: rawptr, data: rawptr, size: c.int) {
		context = runtime.default_context()
		out := (^[dynamic]u8)(ctx)
		append(out, ..([^]u8)(data)[:size])
	}
	ok := stbi.write_png_to_func(sink, &png, c.int(j.w), c.int(j.h), 4, raw_data(p), c.int(j.w * 4)) != 0
	err := ""
	if !ok do err = "the PNG could not be encoded"
	else {
		tmp := strings.concatenate({j.path, ".tmp"}, context.temp_allocator)
		fd := posix.open(strings.clone_to_cstring(tmp, context.temp_allocator), {.WRONLY, .CREAT, .TRUNC, .CLOEXEC}, {.IRUSR, .IWUSR})
		wrote := fd >= 0 && posix.write(fd, raw_data(png), uint(len(png))) == len(png)
		if fd >= 0 do posix.close(fd)
		if !wrote || posix.rename(strings.clone_to_cstring(tmp, context.temp_allocator), strings.clone_to_cstring(j.path, context.temp_allocator)) != 0 {
			posix.unlink(strings.clone_to_cstring(tmp, context.temp_allocator))
			err = "the screenshot could not be written"
		}
	}
	if j.old != "" do posix.unlink(strings.clone_to_cstring(j.old, context.temp_allocator))
	done := App_Call_Done{tab_id = j.tab_id, wire = j.wire, ok = err == "", error = err, from_worker = true, file = err == "" ? j.path : ""}
	if err == "" {
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"path":`)
		json_quote(&b, j.path)
		fmt.sbprintf(&b, `,"w":%d,"h":%d,"bytes":%d,%s}}`, j.w, j.h, len(png), j.meta)
		done.data = strings.to_string(b)
	} else do done.code = "write_failed"
	inbox_submit(done, {kind = .Internal})
	sync.atomic_sub(&shots_running, 1)
}

// ---- inspect boxes (tab.boxes from the app; drawn while inspecting) ----

@(private = "file")
boxes_mu: sync.Mutex
@(private = "file")
boxes: map[u64][]App_Box // per tab, the app's last tab.boxes (written by the socket's readers)
@(private = "file")
boxes_dirty: bool // atomic: new boxes arrived (redraw an inspected tab)

// A tab.boxes event's list: {"boxes":[{id, label?, rect:{x,y,w,h}}]}, at
// most APP_BOXES_MAX, entries without an id or a rect skipped, labels
// capped (none: the id). ok=false if `boxes` is not a list. Heap-owned:
// app_boxes_free.
app_boxes_parse :: proc(line: string) -> (out: []App_Box, ok: bool) {
	v, err := json.parse_string(line, .JSON, true, context.temp_allocator)
	list, is := v.(json.Object)["boxes"].(json.Array)
	if err != nil || !is do return nil, false
	ha := runtime.heap_allocator()
	res := make([dynamic]App_Box, 0, min(len(list), APP_BOXES_MAX), ha)
	num :: proc(o: json.Object, k: string) -> (f32, bool) {
		#partial switch n in o[k] {
		case json.Integer: return f32(n), true
		case json.Float:   return f32(n), true
		}
		return 0, false
	}
	for x in list {
		if len(res) >= APP_BOXES_MAX do break
		o, _ := x.(json.Object)
		id, has_id := o["id"].(json.String)
		r, has_r := o["rect"].(json.Object)
		if !has_id || id == "" || !has_r do continue
		rx, ok1 := num(r, "x")
		ry, ok2 := num(r, "y")
		rw, ok3 := num(r, "w")
		rh, ok4 := num(r, "h")
		if !(ok1 && ok2 && ok3 && ok4) || rw <= 0 || rh <= 0 do continue
		label, _ := o["label"].(json.String)
		if label == "" do label = id
		append(&res, App_Box{id = strings.clone(cap_utf8(id, APP_METHOD_MAX), ha), label = strings.clone(cap_utf8(label, APP_BOX_LABEL_MAX), ha), rect = {rx, ry, rw, rh}})
	}
	return res[:], true
}

// At most n bytes of s, cut at a character, with "…" when cut.
@(private = "file")
cap_utf8 :: proc(s: string, n: int) -> string {
	if len(s) <= n do return s
	i := n
	for i > 0 && (s[i] & 0xC0) == 0x80 do i -= 1
	return strings.concatenate({s[:i], "…"}, context.temp_allocator)
}

app_boxes_free :: proc(list: []App_Box) {
	ha := runtime.heap_allocator()
	for b in list {
		delete(b.id, ha)
		delete(b.label, ha)
	}
	delete(list, ha)
}

// The box at (x, y) (logical tab px): the last listed that holds it (drawn
// on top), -1 = none.
app_box_at :: proc(list: []App_Box, x, y: f32) -> int {
	#reverse for b, i in list {
		if x >= b.rect.x && y >= b.rect.y && x < b.rect.x + b.rect.w && y < b.rect.y + b.rect.h do return i
	}
	return -1
}

// A tab.boxes event (a socket reader): the tab's boxes are replaced.
@(private = "file")
app_boxes_in :: proc(tab_id: u64, line: string) {
	context.allocator = runtime.heap_allocator() // the global map outlives the reader's line
	list, ok := app_boxes_parse(line)
	if !ok do return
	sync.lock(&boxes_mu)
	old := boxes[tab_id] or_else nil
	boxes[tab_id] = list
	sync.unlock(&boxes_mu)
	if old != nil do app_boxes_free(old)
	sync.atomic_store(&boxes_dirty, true)
}

app_boxes_forget :: proc(tab_id: u64) {
	sync.lock(&boxes_mu)
	old, had := boxes[tab_id]
	if had do delete_key(&boxes, tab_id)
	sync.unlock(&boxes_mu)
	if had do app_boxes_free(old)
}

// How many boxes the app sent last (state, tests).
app_box_count :: proc(tab_id: u64) -> int {
	sync.lock(&boxes_mu)
	defer sync.unlock(&boxes_mu)
	return len(boxes[tab_id] or_else nil)
}

// The hovered box's label (temp), "" = none.
app_hover_label :: proc(a: ^App_Proc) -> string {
	if a == nil || !a.inspect || a.hover < 0 do return ""
	sync.lock(&boxes_mu)
	defer sync.unlock(&boxes_mu)
	list := boxes[a.tab_id] or_else nil
	if a.hover >= len(list) do return ""
	return strings.clone(list[a.hover].label, context.temp_allocator)
}

// The pointer moved over an inspected tab: which box it is on. True if that changed.
@(private = "file")
app_hover_at :: proc(a: ^App_Proc, x, y: f32, inside: bool) -> bool {
	h := -1
	if inside {
		sync.lock(&boxes_mu)
		h = app_box_at(boxes[a.tab_id] or_else nil, x, y)
		sync.unlock(&boxes_mu)
	}
	if h == a.hover do return false
	a.hover = h
	return true
}

// The boxes over the tab's frame (app_draw, inside its sgl quads): outlines,
// the hovered one filled, its label in a chip above it.
@(private = "file")
app_draw_boxes :: proc(a: ^App_Proc, x, y, w, h: f32) {
	th := theme()
	sync.lock(&boxes_mu)
	defer sync.unlock(&boxes_mu)
	list := boxes[a.tab_id] or_else nil
	if a.hover >= len(list) do a.hover = -1
	s := app.dpi
	t := max(1, math.round(s))
	label_x, label_y: f32
	label := ""
	for b, i in list {
		bx0, by0 := max(x + b.rect.x * s, x), max(y + b.rect.y * s, y)
		bx1, by1 := min(x + (b.rect.x + b.rect.w) * s, x + w), min(y + (b.rect.y + b.rect.h) * s, y + h)
		if bx1 <= bx0 || by1 <= by0 do continue
		col := th.accent
		if i == a.hover {
			draw_rect(bx0, by0, bx1 - bx0, by1 - by0, with_alpha(th.accent, 0.25))
			label, label_x, label_y = b.label, bx0, by0
		}
		draw_rect(bx0, by0, bx1 - bx0, t, col)
		draw_rect(bx0, by1 - t, bx1 - bx0, t, col)
		draw_rect(bx0, by0, t, by1 - by0, col)
		draw_rect(bx1 - t, by0, t, by1 - by0, col)
	}
	if label == "" do return
	lh := text_line_height(.UI)
	pad := px(SP_1)
	tw := min(text_width(label, .UI), w - 2 * pad)
	shown := text_clip(label, tw, .UI)
	cw, ch := tw + 2 * pad, lh + pad
	cx := clamp(label_x, x, x + w - cw)
	cy := label_y - ch - t
	if cy < y do cy = label_y + t // no room above: inside the box's top
	draw_rect(cx, cy, cw, ch, th.bg_elevated)
	draw_rect(cx, cy, cw, t, th.border)
	draw_text(cx + pad, cy + pad / 2, shown, th.text)
}

// ---- input (event(): after pi-desk's shortcuts and open widgets) ----

// The sokol key code's name in lower case ("a", "left_shift", "1"); "" = unmapped.
app_key_name :: proc(k: sapp.Keycode) -> string {
	if k == .INVALID do return ""
	n := strings.to_lower(fmt.tprint(k), context.temp_allocator)
	return strings.trim_prefix(n, "_")
}

@(private = "file")
mods_json :: proc(m: u32) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_byte(&b, '[')
	first := true
	add :: proc(b: ^strings.Builder, first: ^bool, s: string) {
		if !first^ do strings.write_byte(b, ',')
		first^ = false
		fmt.sbprintf(b, `"%s"`, s)
	}
	if m & sapp.MODIFIER_SHIFT != 0 do add(&b, &first, "shift")
	if m & sapp.MODIFIER_CTRL != 0 do add(&b, &first, "ctrl")
	if m & sapp.MODIFIER_ALT != 0 do add(&b, &first, "alt")
	if m & sapp.MODIFIER_SUPER != 0 do add(&b, &first, "cmd")
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

@(private = "file")
button_name :: proc(b: sapp.Mousebutton) -> string {
	#partial switch b {
	case .LEFT:   return "left"
	case .RIGHT:  return "right"
	case .MIDDLE: return "middle"
	}
	return ""
}

@(private = "file")
send_input :: proc(a: ^App_Proc, line: string) {
	if socket_app_send(a.tab_id, line) do a.inputs += 1
}

// Lets go of what the app holds: key-ups and button-ups for everything
// still pressed, then focus off (focus loss, a hidden tab, a closed tab).
app_release_input :: proc(a: ^App_Proc) {
	for k in a.held do send_input(a, fmt.tprintf(`{{"v":1,"type":"input","event":"key","action":"up","key":"%s","repeat":false,"mods":[]}}`, app_key_name(k)))
	clear(&a.held)
	for b in a.buttons do send_input(a, fmt.tprintf(`{{"v":1,"type":"input","event":"mouse","action":"up","button":"%s","x":%.1f,"y":%.1f,"clicks":1,"mods":[]}}`, button_name(sapp.Mousebutton(b)), a.last_x, a.last_y))
	a.buttons = {}
	if a.focused {
		send_input(a, `{"v":1,"type":"input","event":"focus","focused":false}`)
		a.focused = false
	}
}

// Every frame: the app on screen has the keyboard while no widget has it
// and the window is active; any other app lets go.
app_focus_tick :: proc() {
	if len(apps) == 0 do return
	for _, a in apps {
		want := app_wants_keys(a)
		if want == a.focused do continue
		if !want do app_release_input(a)
		else if socket_app_connected(a.tab_id) {
			send_input(a, `{"v":1,"type":"input","event":"focus","focused":true}`)
			a.focused = true
		}
	}
}

// The app has the keyboard: its tab is the focused one (panes.odin), it runs, no widget has the
// keyboard, the job sheet is shut and the window is in front.
app_wants_keys :: proc(a: ^App_Proc) -> bool {
	return tab_focused(a.tab_id) && a.pid != 0 && state.focus_widget == "" && !job_sheet_open() && app.window_active
}

@(private = "file")
in_tab :: proc(p: [4]f32, x, y: f32) -> bool {
	return p.z > 0 && x >= p.x && y >= p.y && x < p.x + p.z && y < p.y + p.w
}

// Forwards the event to the app pane p shows. True if it took it. Keys only
// while no widget has the keyboard (and never under the modal job sheet);
// the mouse not under the palette, a menu, a popover, a sheet or Atlas's
// drawer; a press keeps the moves and the release until the button is up.
app_event :: proc(p: ^Pane, e: ^sapp.Event) -> bool {
	a := pane_app(p)
	if a == nil do return false
	r := pane_rect(p)
	if e.type == .MOUSE_DOWN && app_bar_click(a, e.mouse_x, e.mouse_y) do return true
	if a.pid == 0 do return false
	overlay := palette_is_open() || menu.open || settings_open() || shortcuts_open() || setup_open() || job_sheet_open() || bell_open()
	covered := overlay || (state.home_open && inside(clay.ID("drawer"), e.mouse_x, e.mouse_y))
	x, y := (e.mouse_x - r.x) / app.dpi, (e.mouse_y - r.y) / app.dpi
	// inspecting: the mouse over the tab is pi-desk's (hover shows a box's
	// label); a press already held in the app still gets its moves and release
	if a.inspect && a.buttons == {} {
		#partial switch e.type {
		case .MOUSE_MOVE:
			a.hx, a.hy, a.hin = x, y, !covered && in_tab(r, e.mouse_x, e.mouse_y)
			if app_hover_at(a, x, y, a.hin) do app.redraw = true
			return a.hin
		case .MOUSE_DOWN, .MOUSE_UP, .MOUSE_SCROLL:
			if covered || !in_tab(r, e.mouse_x, e.mouse_y) do return false
			// a click on a box: a comment on it for this tab's session's pi
			if e.type == .MOUSE_DOWN && e.mouse_button == .LEFT {
				// copied under the lock; the crop and the bar after it (they take their time)
				sync.lock(&boxes_mu)
				list := boxes[a.tab_id] or_else nil
				hit, found := App_Box{}, false
				if i := app_box_at(list, x, y); i >= 0 {
					hit = {id = strings.clone(list[i].id, context.temp_allocator), label = strings.clone(list[i].label, context.temp_allocator), rect = list[i].rect}
					found = true
				}
				sync.unlock(&boxes_mu)
				if found do comments_draft_box(a.tab_id, hit, app_box_crop(a.tab_id, hit.rect))
			}
			return true
		case .MOUSE_LEAVE:
			a.hin = false
			if app_hover_at(a, x, y, false) do app.redraw = true
			return false
		}
	}
	#partial switch e.type {
	case .KEY_DOWN, .CHAR, .KEY_UP:
		if state.focus_widget != "" || job_sheet_open() do return false
		if e.modifiers & sapp.MODIFIER_SUPER != 0 do return false // pi-desk's shortcuts
	case .MOUSE_DOWN, .MOUSE_SCROLL:
		if covered do return false
	case .MOUSE_MOVE:
		if covered && a.buttons == {} do return false
	}
	#partial switch e.type {
	case .KEY_DOWN:
		k := app_key_name(e.key_code)
		if k == "" do return true // unmapped: never sent as another key
		if !a.focused do app_focus_tick()
		if !slice.contains(a.held[:], e.key_code) do append(&a.held, e.key_code)
		send_input(a, fmt.tprintf(`{{"v":1,"type":"input","event":"key","action":"down","key":"%s","repeat":%v,"mods":%s}}`, k, e.key_repeat, mods_json(e.modifiers)))
		return true
	case .KEY_UP:
		k := app_key_name(e.key_code)
		if k == "" do return true
		i, found := slice.linear_search(a.held[:], e.key_code)
		if !found do return true // its press went elsewhere
		unordered_remove(&a.held, i)
		send_input(a, fmt.tprintf(`{{"v":1,"type":"input","event":"key","action":"up","key":"%s","repeat":false,"mods":%s}}`, k, mods_json(e.modifiers)))
		return true
	case .CHAR:
		if e.char_code < 0x20 || e.char_code == 0x7f do return true // control keys went as key downs
		r, ok := utf16_unit(&app_surrogate, e.char_code)
		if !ok do return true
		b := strings.builder_make(context.temp_allocator)
		json_quote(&b, utf8_string(r))
		send_input(a, fmt.tprintf(`{{"v":1,"type":"input","event":"char","text":%s}}`, strings.to_string(b)))
		return true
	case .MOUSE_DOWN:
		if !in_tab(r, e.mouse_x, e.mouse_y) do return false
		// a click in the tab takes the keyboard back; a sliding drawer goes away
		if state.home_open && !state.layout.drawer_pinned do ui_do(Set_Home{open = false})
		if state.focus_widget != "" do ui_do(Set_Focus{""})
		ime_cancel()
		bn := button_name(e.mouse_button)
		if bn == "" do return true
		a.buttons += {int(e.mouse_button)}
		a.last_x, a.last_y = x, y
		send_input(a, fmt.tprintf(`{{"v":1,"type":"input","event":"mouse","action":"down","button":"%s","x":%.1f,"y":%.1f,"clicks":%d,"mods":%s}}`, bn, x, y, max(app.clicks, 1), mods_json(e.modifiers)))
		return true
	case .MOUSE_UP:
		if int(e.mouse_button) > 2 || int(e.mouse_button) not_in a.buttons do return false
		a.buttons -= {int(e.mouse_button)}
		a.last_x, a.last_y = x, y
		send_input(a, fmt.tprintf(`{{"v":1,"type":"input","event":"mouse","action":"up","button":"%s","x":%.1f,"y":%.1f,"clicks":%d,"mods":%s}}`, button_name(e.mouse_button), x, y, max(app.clicks, 1), mods_json(e.modifiers)))
		return true
	case .MOUSE_MOVE:
		inside_tab := in_tab(r, e.mouse_x, e.mouse_y)
		if !inside_tab && a.buttons == {} do return false
		dx, dy := x - a.last_x, y - a.last_y
		a.last_x, a.last_y = x, y
		send_input(a, fmt.tprintf(`{{"v":1,"type":"input","event":"move","x":%.1f,"y":%.1f,"dx":%.1f,"dy":%.1f}}`, x, y, dx, dy))
		return inside_tab
	case .MOUSE_SCROLL:
		if !in_tab(r, e.mouse_x, e.mouse_y) do return false
		send_input(a, fmt.tprintf(`{{"v":1,"type":"input","event":"scroll","dx":%.2f,"dy":%.2f,"x":%.1f,"y":%.1f}}`, e.scroll_x, e.scroll_y, x, y))
		return true
	}
	return false
}

// ---- the bar (ui.odin's centre): Inspect; exited / not responding / no frames ----

app_bar_layout :: proc(p: ^Pane) {
	a := pane_app(p)
	if a == nil do return
	_, tab, at := app_tab_of(a.tab_id)
	if tab == nil do return
	text: string
	restart, wait := false, false
	switch at.app_status {
	case .Exited:
		text = fmt.tprintf("%s exited (code %d)", a.title, at.exit_code)
		restart = true
	case .Not_Responding:
		text = fmt.tprintf("%s is not responding", a.title)
		restart, wait = true, true
	case .Stalled:
		text = fmt.tprintf("No frames for %ds", int(time.duration_seconds(time.tick_since(a.ring.last_frame))))
	case .Starting, .Running:
	}
	th := theme()
	if clay.UI(cid("app_bar"))({
		clip = {horizontal = true}, // its pane's width at most (bar_w)
		layout = {sizing = {bar_w(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childGap = pu(SP_2), childAlignment = {y = .Center}},
		backgroundColor = cc(th.bg_elevated),
		border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
	}) {
		if text != "" {
			dot(at.app_status == .Stalled ? th.waiting : th.error)
			clay.TextDynamic(text, txt(th.text))
		}
		spacer()
		if a.inspect do clay.TextDynamic(fmt.tprintf("%d boxes", app_box_count(a.tab_id)), txt(th.text_muted))
		// the app's boxes over the tab (tab.boxes); on: highlighted
		button(cid("app_inspect"), "Inspect", a.inspect, clay.PointerOver(cid("app_inspect")))
		if wait do button(cid("app_wait"), "Wait", false, clay.PointerOver(cid("app_wait")))
		if text != "" do button(cid("app_log"), "Log", false, clay.PointerOver(cid("app_log")))
		if restart do button(cid("app_restart"), "Restart", true, clay.PointerOver(cid("app_restart")))
	}
}

// A click on the bar's buttons. True if it took it.
@(private = "file")
app_bar_click :: proc(a: ^App_Proc, x, y: f32) -> bool {
	if cinside("app_inspect", x, y) {
		ui_do(App_Inspect{tab_id = a.tab_id, on = !a.inspect})
		return true
	}
	if cinside("app_restart", x, y) {
		ui_do(App_Restart{tab_id = a.tab_id})
		return true
	}
	if cinside("app_log", x, y) {
		if s, _, _ := find_tab(a.tab_id); s != nil do ui_do(Open_File{path = a.log_path, session = s.id})
		return true
	}
	if cinside("app_wait", x, y) {
		// keep waiting: the next silence starts a new ping
		a.ping_at, a.ping_answered = time.tick_now(), false
		a.ring.last_frame = time.tick_now()
		a.stalled = false
		app.redraw = true
		return true
	}
	return false
}

// ---- the palette's app mode ("New app tab…") ----

// Apps listed in the session's .pi-desk/apps.json ({"apps":[{"name","argv","cwd"?}]}).
App_Entry :: struct {
	name: string,
	argv: []string,
	cwd:  string,
}

app_entries :: proc(cwd: string) -> []App_Entry {
	path, _ := filepath.join({cwd, ".pi-desk", "apps.json"}, context.temp_allocator)
	data, ok := app_json_read(path)
	if !ok do return nil
	v, perr := json.parse(data, .JSON, true, context.temp_allocator)
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
	if len(names) == 0 do return fmt.tprintf("no app %q: the session's folder declares none (.pi-desk/apps.json)", name)
	return fmt.tprintf("no app %q in the session's .pi-desk/apps.json (declared: %s)", name, strings.join(names[:], ", ", context.temp_allocator))
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

// The palette's app mode: the typed command line, then the session's
// apps.json entries matching it.
app_palette_results :: proc(query: string) -> []Palette_Item {
	out := make([dynamic]Palette_Item, context.temp_allocator)
	q := strings.trim_space(query)
	if q != "" do append(&out, Palette_Item{kind = .App, key = "app:run", title = fmt.tprintf("Run “%s” in an app tab", q), path = strings.clone(q, context.temp_allocator), order = 0})
	if cs := cur(); cs != nil {
		for e, i in app_entries(cs.cwd) {
			if q != "" && !strings.contains(strings.to_lower(e.name, context.temp_allocator), strings.to_lower(q, context.temp_allocator)) do continue
			append(&out, Palette_Item{kind = .App, key = strings.concatenate({"app:", e.name}, context.temp_allocator), title = e.name, detail = strings.join(e.argv, " ", context.temp_allocator), order = i + 1})
		}
	}
	return out[:]
}

// ---- test mode (autotest.odin hands these lines over) ----
//
//   app_open ARGV...            an app tab in the current session (argv[0] relative: from the repo)
//   app_waitframe [N] [MS]      until N more frames were shown (default 1; 5 s)
//   app_waitstatus STATUS [MS]  until the app on screen is starting|running|stalled|not_responding|exited
//   app_waitlog TEXT [MS]       until the app's log has a line containing TEXT
//   assert_app_log TEXT         the app's log has a line containing TEXT; assert_not_app_log: not
//   assert_app_pixel X Y RRGGBB the shown frame at tab X,Y (logical) is RRGGBB (±8)
//   app_square                  find the red square (#FF4040) on row y=60 of the shown frame; log its x
//   assert_app_moved            the square's x differs from the previous app_square's
//   app_mark                    remember the current ring gen
//   app_waitring [MS]           until a newer ring than app_mark's shows a frame at the pane's size
//   assert_app_surfaces N       IOSurfaces alive for the tab
//   assert_apps_freed           no app tabs: no surfaces, send rights, images or app state left
//   app_click X Y               a left click at tab X,Y through pi-desk's event path
//   app_keydown LETTER          a key press without its release
//   app_drag X1 Y1 X2 Y2        a left drag in tab coordinates (the end may be outside the tab)
//   assert_app_dimmed yes|no    the last frame of an app that exited shows dimmed
//   app_stats                   frames, latency (FRAME received -> pi-desk's GPU frame done) p50/p95/max
//   app_hover X Y               the pointer moves to tab X,Y through pi-desk's event path
//   app_mouse down|up X Y       one left press or release at tab X,Y (a press held across lines)
//   app_leave                   the pointer leaves the window
//   assert_app_hover LABEL|-    while inspecting, the box under the pointer has LABEL (- = none)
//   assert_shot_pixel X Y RRGGBB  the last finished app_screenshot's PNG at px X,Y is RRGGBB (±8)

app_last_finished: string // autotest's last finished result (assert_shot_pixel)

App_Wait :: struct {
	kind:     string, // "" = none
	text:     string,
	n:        u64,
	deadline: time.Tick,
}
app_wait: App_Wait
@(private = "file")
app_marks: struct {
	gen:    u32,
	square: [2]int,
	tab:    u64, // the last app tab app_open opened: the script's app while none is on screen
}

// The script's app: the one on screen, else the last one opened.
@(private = "file")
script_app :: proc() -> ^App_Proc {
	if a := tab_app(); a != nil do return a
	return app_of(app_marks.tab)
}

@(private = "file")
aw_set :: proc(kind: string, ms: f64, text := "", n: u64 = 0) {
	delete(app_wait.text)
	app_wait = {kind = kind, text = strings.clone(text), n = n, deadline = time.tick_add(time.tick_now(), time.Duration(ms * f64(time.Millisecond)))}
}

@(private = "file")
num_arg :: proc(args: []string, i: int, def: f64) -> f64 {
	if i < len(args) {
		if v, ok := strconv.parse_f64(args[i]); ok do return v
	}
	return def
}

@(private = "file")
shown_pixel :: proc(a: ^App_Proc, x, y: f32) -> (u32, bool) {
	if a.ring.shown_gen == 0 do return 0, false
	rgb: u32
	g := ring_gen(&a.ring, a.ring.shown_gen)
	s := g != nil ? g.scale : app.dpi
	if pd_frames_pixel(a.tab_id, a.ring.shown_gen, c.int(a.ring.shown_slot), c.int(x * s), c.int(y * s), &rgb) == 0 do return 0, false
	return rgb, true
}

@(private = "file")
rgb_close :: proc(a, b: u32) -> bool {
	for s in ([]u32{0, 8, 16}) {
		d := int((a >> s) & 0xFF) - int((b >> s) & 0xFF)
		if d < -8 || d > 8 do return false
	}
	return true
}

// A pending app_* wait: true when the script may go on.
app_wait_done :: proc(fail: proc(msg: string)) -> bool {
	w := &app_wait
	if w.kind == "" do return true
	a := script_app()
	done := false
	got := ""
	if a != nil {
		_, _, at := app_tab_of(a.tab_id)
		switch w.kind {
		case "frame":
			done = a.ring.shown >= w.n
			got = fmt.tprintf("%d frames shown", a.ring.shown)
		case "status":
			got = at != nil ? APP_STATUS_NAMES[at.app_status] : "?"
			done = got == w.text
		case "log":
			done = app_log_has(a, w.text)
			got = done ? "in the log" : "not in the log"
		case "ring":
			g := ring_gen(&a.ring, a.ring.shown_gen)
			r := tab_rect(a.tab_id)
			w_px, h_px := int(math.round(r.z)), int(math.round(r.w))
			done = g != nil && a.ring.shown_gen > app_marks.gen && g.w == w_px && g.h == h_px
			got = g != nil ? fmt.tprintf("shown gen %d %dx%d, pane %dx%d", g.gen, g.w, g.h, w_px, h_px) : "nothing shown"
		}
	}
	if done {
		fmt.printfln("[app] %s reached: %s", w.kind, got)
	} else if time.tick_diff(w.deadline, time.tick_now()) > 0 {
		fail(fmt.tprintf("ASSERT FAILED app wait %s %q: got %s", w.kind, w.text, got))
	} else do return false
	w.kind = ""
	return true
}

// One app_* line. ok=false: a failure message for the script.
app_script :: proc(cmd: string, args: []string, rest: string) -> (msg: string, ok: bool) {
	a := script_app()
	switch cmd {
	case "app_open":
		if len(args) == 0 do return "app_open ARGV...", false
		argv := make([]string, len(args), context.temp_allocator)
		copy(argv, args)
		if !filepath.is_abs(argv[0]) && strings.contains(argv[0], "/") {
			cwd, _ := os.get_working_directory(context.temp_allocator)
			argv[0], _ = filepath.join({cwd, argv[0]}, context.temp_allocator)
		}
		r := run_command(New_App_Tab{argv = argv}, {kind = .Script})
		if !r.ok do return fmt.tprintf("app_open: %s", r.error), false
		autotest.last_created = r.created_id
		app_marks.tab = r.created_id
		return "", true
	case "app_waitframe":
		if a == nil do return "app_waitframe: no app tab on screen", false
		aw_set("frame", num_arg(args, 1, 5000), n = a.ring.shown + u64(num_arg(args, 0, 1)))
		return "", true
	case "app_waitstatus":
		if len(args) < 1 do return "app_waitstatus STATUS [MS]", false
		aw_set("status", num_arg(args, 1, 5000), args[0])
		return "", true
	case "app_waitlog":
		if len(args) < 1 do return "app_waitlog TEXT [MS]", false
		text, ms := rest, 5000.0
		if len(args) > 1 {
			if v, vok := strconv.parse_f64(args[len(args) - 1]); vok {
				ms = v
				text = strings.trim_space(rest[:strings.last_index(rest, args[len(args) - 1])])
			}
		}
		aw_set("log", ms, text)
		return "", true
	case "assert_app_log", "assert_not_app_log":
		if a == nil do return fmt.tprintf("%s: no app tab on screen", cmd), false
		has := app_log_has(a, rest)
		if has != (cmd == "assert_app_log") do return fmt.tprintf("ASSERT FAILED %s %q", cmd, rest), false
		fmt.printfln("[app] assert ok: %s %q", cmd, rest)
		return "", true
	case "assert_app_pixel":
		if a == nil || len(args) < 3 do return "assert_app_pixel X Y RRGGBB (an app tab on screen)", false
		want, _ := strconv.parse_u64(args[2], 16)
		got, gok := shown_pixel(a, f32(num_arg(args, 0, 0)), f32(num_arg(args, 1, 0)))
		if !gok || !rgb_close(got, u32(want)) do return fmt.tprintf("ASSERT FAILED assert_app_pixel %s: got %06x (read %v)", rest, got, gok), false
		fmt.printfln("[app] assert ok: pixel %s,%s = %06x", args[0], args[1], got)
		return "", true
	case "app_square":
		if a == nil do return "app_square: no app tab on screen", false
		g := ring_gen(&a.ring, a.ring.shown_gen)
		if g == nil do return "app_square: nothing shown", false
		x := -1
		for lx in 0 ..< int(f32(g.w) / g.scale) {
			if px, pok := shown_pixel(a, f32(lx), 60); pok && rgb_close(px, 0xFF4040) {
				x = lx
				break
			}
		}
		app_marks.square = {app_marks.square[1], x}
		fmt.printfln("[app] square at x=%d (seq %d, tick %d)", x, a.ring.shown_seq, a.ring.shown_tick)
		if x < 0 do return "ASSERT FAILED app_square: no square on row 60", false
		return "", true
	case "assert_app_moved":
		if app_marks.square[0] < 0 || app_marks.square[0] == app_marks.square[1] do return fmt.tprintf("ASSERT FAILED assert_app_moved: %d -> %d", app_marks.square[0], app_marks.square[1]), false
		fmt.printfln("[app] assert ok: the square moved %d -> %d", app_marks.square[0], app_marks.square[1])
		return "", true
	case "app_mark":
		if a == nil do return "app_mark: no app tab on screen", false
		app_marks.gen = a.ring.cur_gen
		fmt.printfln("[app] mark: ring gen %d", app_marks.gen)
		return "", true
	case "app_waitring":
		aw_set("ring", num_arg(args, 0, 5000))
		return "", true
	case "assert_app_surfaces":
		if a == nil || len(args) < 1 do return "assert_app_surfaces N", false
		n := int(pd_frames_surface_count(a.tab_id))
		if fmt.tprint(n) != args[0] do return fmt.tprintf("ASSERT FAILED assert_app_surfaces: %d alive, want %s", n, args[0]), false
		fmt.printfln("[app] assert ok: %d surfaces", n)
		return "", true
	case "assert_apps_freed":
		// every app tab closed: no surfaces, no images, no app state
		n, peers := int(pd_frames_surface_total()), int(pd_frames_peers())
		if n != 0 || peers != 0 || app_images != 0 || len(apps) != 0 || len(dying) != 0 || len(reap) != 0 do return fmt.tprintf("ASSERT FAILED assert_apps_freed: %d surfaces, %d send rights, %d images, %d apps, %d closing, %d to reap", n, peers, app_images, len(apps), len(dying), len(reap)), false
		fmt.printfln("[app] assert ok: apps freed")
		return "", true
	case "app_click":
		if a == nil || len(args) < 2 do return "app_click X Y (an app tab on screen)", false
		r := tab_rect(a.tab_id)
		x, y := r.x + f32(num_arg(args, 0, 0)) * app.dpi, r.y + f32(num_arg(args, 1, 0)) * app.dpi
		app.clicks = 1
		e := sapp.Event{type = .MOUSE_MOVE, mouse_x = x, mouse_y = y}
		event(&e)
		e = {type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x, mouse_y = y}
		event(&e)
		e = {type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x, mouse_y = y}
		event(&e)
		return "", true
	case "app_keydown":
		// a key press without its release (KEY_DOWN + CHAR): what is held when the app loses focus
		if len(args) < 1 || len(args[0]) != 1 || args[0][0] < 'a' || args[0][0] > 'z' do return "app_keydown LETTER", false
		r := args[0][0]
		e := sapp.Event{type = .KEY_DOWN, key_code = sapp.Keycode(int(sapp.Keycode.A) + int(r - 'a'))}
		event(&e)
		e = {type = .CHAR, char_code = u32(r)}
		event(&e)
		return "", true
	case "app_drag":
		// a left drag in tab coordinates; the end may be outside the tab (the app keeps the capture)
		if a == nil || len(args) < 4 do return "app_drag X1 Y1 X2 Y2", false
		p := [4]f32{f32(num_arg(args, 0, 0)), f32(num_arg(args, 1, 0)), f32(num_arg(args, 2, 0)), f32(num_arg(args, 3, 0))}
		r := tab_rect(a.tab_id)
		x1, y1 := r.x + p[0] * app.dpi, r.y + p[1] * app.dpi
		x2, y2 := r.x + p[2] * app.dpi, r.y + p[3] * app.dpi
		app.clicks = 1
		e := sapp.Event{type = .MOUSE_DOWN, mouse_button = .LEFT, mouse_x = x1, mouse_y = y1}
		event(&e)
		e = {type = .MOUSE_MOVE, mouse_x = x2, mouse_y = y2, modifiers = sapp.MODIFIER_LMB}
		event(&e)
		e = {type = .MOUSE_UP, mouse_button = .LEFT, mouse_x = x2, mouse_y = y2}
		event(&e)
		return "", true
	case "assert_app_dimmed":
		if a == nil || len(args) < 1 do return "assert_app_dimmed yes|no", false
		dim := a.pid == 0 && a.ring.shown_gen != 0 // app_draw dims the kept last frame
		if (args[0] == "yes") != dim do return fmt.tprintf("ASSERT FAILED assert_app_dimmed %s: pid %d, shown gen %d", args[0], a.pid, a.ring.shown_gen), false
		fmt.printfln("[app] assert ok: dimmed %s", args[0])
		return "", true
	case "app_stats":
		if a == nil do return "app_stats: no app tab on screen", false
		p: Frames_Poll
		lat: [512]f64
		n := int(pd_frames_latency(a.tab_id, &lat[0], len(lat)))
		s := lat[:n]
		slice.sort(s)
		pct :: proc(s: []f64, q: f64) -> f64 {return len(s) == 0 ? 0 : s[min(int(q * f64(len(s))), len(s) - 1)]}
		fmt.printfln("[app] stats: shown %d, inputs sent %d, ring gen %d, qlimit %d; latency FRAME received -> drawn (GPU done) n=%d p50 %.2f ms p95 %.2f ms max %.2f ms", a.ring.shown, a.inputs, a.ring.cur_gen, pd_frames_qlimit(), n, pct(s, 0.5), pct(s, 0.95), n > 0 ? s[n - 1] : 0)
		_ = p
		return "", true
	case "app_hover":
		if a == nil || len(args) < 2 do return "app_hover X Y (an app tab on screen)", false
		r := tab_rect(a.tab_id)
		e := sapp.Event{type = .MOUSE_MOVE, mouse_x = r.x + f32(num_arg(args, 0, 0)) * app.dpi, mouse_y = r.y + f32(num_arg(args, 1, 0)) * app.dpi}
		event(&e)
		return "", true
	case "app_mouse":
		if a == nil || len(args) < 3 do return "app_mouse down|up X Y", false
		r := tab_rect(a.tab_id)
		e := sapp.Event{type = args[0] == "down" ? .MOUSE_DOWN : .MOUSE_UP, mouse_button = .LEFT, mouse_x = r.x + f32(num_arg(args, 1, 0)) * app.dpi, mouse_y = r.y + f32(num_arg(args, 2, 0)) * app.dpi}
		app.clicks = 1
		event(&e)
		return "", true
	case "app_leave":
		e := sapp.Event{type = .MOUSE_LEAVE}
		event(&e)
		return "", true
	case "assert_app_hover":
		if a == nil || len(args) < 1 do return "assert_app_hover LABEL|-", false
		want := strings.trim_space(rest)
		got := app_hover_label(a)
		if want == "-" do want = ""
		if got != want do return fmt.tprintf("ASSERT FAILED assert_app_hover: got %q, want %q", got, want), false
		fmt.printfln("[app] assert ok: hover %q", got)
		return "", true
	case "assert_shot_pixel":
		if len(args) < 3 do return "assert_shot_pixel X Y RRGGBB", false
		path := json_path(app_last_finished, "data.path")
		w, h, n: c.int
		px := stbi.load(strings.clone_to_cstring(path, context.temp_allocator), &w, &h, &n, 4)
		if px == nil do return fmt.tprintf("ASSERT FAILED assert_shot_pixel: cannot read %q", path), false
		defer stbi.image_free(px)
		x, y := int(num_arg(args, 0, 0)), int(num_arg(args, 1, 0))
		if x < 0 || y < 0 || x >= int(w) || y >= int(h) do return fmt.tprintf("ASSERT FAILED assert_shot_pixel: %d,%d outside %dx%d", x, y, w, h), false
		q := px[(y * int(w) + x) * 4:]
		got := u32(q[0]) << 16 | u32(q[1]) << 8 | u32(q[2])
		want, _ := strconv.parse_u64(args[2], 16)
		if !rgb_close(got, u32(want)) do return fmt.tprintf("ASSERT FAILED assert_shot_pixel %s: got %06x", rest, got), false
		fmt.printfln("[app] assert ok: shot pixel %d,%d = %06x (%dx%d)", x, y, got, w, h)
		return "", true
	}
	return fmt.tprintf("unknown command %s", cmd), false
}
