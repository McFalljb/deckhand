package main

// Agents read pages (docs/BROWSER.md §4, step 7): browser_tabs, browser_read, browser_screenshot,
// browser_wait, browser_console, browser_network, browser_comments, and the agent strip with its
// Stop button. The navigation commands (browser_open, browser_navigate, …) are step 2's
// (browser_nav.odin); they show the strip too.
//
// Who: the table class Own_Session. A pi tab (its bridge, caller panel) sees and drives only its
// own session's browser tabs (browser_target); Atlas and other control callers name any session
// or tab. A browser tab belongs to one session for its life (browser.odin). No site list: agents
// read any site without asking (user decision, BROWSER.md §8 decision 4); file: stays the user's
// (browser_open, browser_navigate).
//
// How: in process, through the tab's DevTools session (dh_cef_devtools_send; results come back
// through browser_annotate.odin's observer callback, which hands ours over first: ids from
// AGENT_MSG_BASE up). Reads run src/native/browser_read.js in the overlay's isolated world
// ("deckhand", the context of its latest hello): the page's scripts cannot see or change it, and
// form values are never read ("[value hidden]", as comment mode). Long commands (read, wait,
// screenshot) are ops ticked every frame (browser_agent_tick), finished with a Finished_Event;
// a read's data is private (only its requester gets the page's text; the log sees its size).
//
// Console and network: the Runtime, Log and Network domains are a bot check's tell (and route
// every console message through Deckhand), so they are off by default. The first browser_console
// (Runtime + Log) or browser_network (Network) on a tab turns that recording on, for
// AGENT_CAPTURE_FOR after the last such call; it ends sooner when the top document goes to
// another origin or the user presses Stop (a page that reopens meanwhile records again). While
// it is on the strip says so. Messages from before it started are not there (a reload shows a
// page's load).
//
// Screenshots: the frame ring (frame_shot, as app_screenshot). A tab not on screen is woken for
// the shot (CEF paints it, hidden from the user), then hidden again; the user's view never
// changes and no page is unloaded for an agent (an unloaded tab loads only into a free slot).
//
// The strip: on the browser toolbar (not a bar of its own: the page would be resized by a read),
// "pi is reading this page · Stop" while an agent's command runs on the tab, for
// AGENT_STRIP_LINGER after, and while recording is on. Stop cancels the tab's agent commands in
// flight (their callers get "stopped by the user") and ends the recording.

import "core:c"
import "core:encoding/json"
import jg "jsonguard"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import clay "../build/clay-odin"

BROWSER_READ_JS :: #load("native/browser_read.js", string)
AGENT_MSG_BASE :: c.int(1 << 30) // our CDP ids (the overlay's count up from 1)
AGENT_READ_MAX :: 20_000 // characters browser_read returns by default
AGENT_READ_LIMIT :: 200_000 // and at most
AGENT_READ_TIMEOUT :: 15 * time.Second // a read waits this long for the page (opening, its overlay)
AGENT_WAIT_DEFAULT :: 10 * time.Second
AGENT_WAIT_LIMIT :: 120 * time.Second
AGENT_POLL :: 200 * time.Millisecond // browser_wait asks the page this often
AGENT_SHOT_TIMEOUT :: 5 * time.Second // a hidden tab's frame
// A tab on screen: its view's size unchanged this long before the frame taken is asked for (a
// frame from just after a resize, such as the agent strip appearing, holds the old page scaled
// into the new size, black at the sides)
AGENT_SHOT_SETTLE :: 200 * time.Millisecond
AGENT_NAV_SETTLE :: 3 * time.Second // a load wait right after a navigation: its document, or this long
AGENT_CAPTURE_FOR :: 5 * time.Minute // console/network recording after the last call
AGENT_LOG_MAX :: 300 // entries kept per tab and kind
AGENT_TEXT_MAX :: 2000 // bytes of an entry's text
AGENT_URL_MAX :: 500
AGENT_STRIP_LINGER :: 4 * time.Second

// ---- commands (rows in command_table.odin) ----

Browser_Tabs :: struct {
	session: u64, // 0: a pi tab's own; for others every session's
}
Browser_Read :: struct {
	tab_id:   u64,
	mode:     string, // text (default) | outline | html
	selector: string, // a CSS selector or ref=eN (an outline's); "" = the whole page
	max:      int, // characters (0 = AGENT_READ_MAX)
}
Browser_Screenshot :: struct {
	tab_id:   u64,
	rect:     App_Rect, // the page's CSS px from its top-left (the viewport)
	has_rect: bool,
}
Browser_Page_Wait :: struct {
	tab_id:     u64,
	what:       string, // load | selector | text (the wire's "for")
	value:      string, // the selector or the text
	timeout_ms: int,
}
Browser_Console :: struct {
	tab_id: u64,
	since:  u64,
	limit:  int,
}
Browser_Network :: struct {
	tab_id: u64,
	since:  u64,
	limit:  int,
}
Browser_Comments :: struct {
	tab_id:  u64, // 0: the session's
	session: u64,
}
Browser_Agent_Stop :: struct {
	tab_id: u64,
}

// ---- runtime ----

Agent_Doing :: enum u8 {
	Reading,
	Waiting,
	Driving,
	// actions (browser_act.odin): the strip names their target
	Clicking,
	Typing,
	Pressing,
	Scrolling,
	Choosing,
	Hovering,
	Uploading,
}
AGENT_DOING_NAMES := [Agent_Doing]string {
	.Reading   = "reading",
	.Waiting   = "waiting on",
	.Driving   = "driving",
	.Clicking  = "clicking",
	.Typing    = "typing into",
	.Pressing  = "pressing keys in",
	.Scrolling = "scrolling",
	.Choosing  = "choosing in",
	.Hovering  = "pointing at",
	.Uploading = "uploading to",
}

Agent_Log :: struct {
	seq:    u64,
	level:  string, // owned
	text:   string, // owned
	source: string, // owned: url:line
}
Agent_Net :: struct {
	seq:    u64, // bumped when its response or failure arrives (it shows again after `since`)
	id:     string, // owned: CDP's requestId
	method: string, // owned
	url:    string, // owned, without user:pass@
	kind:   string, // owned: Document, XHR, Fetch, Image…
	status: int,
	mime:   string, // owned
	failed: string, // owned: the error ("" = none)
	done:   bool,
}

// Per browser tab (runtime, keyed by tab id).
Agent_Tab :: struct {
	tab_id:        u64,
	who:           Caller_Kind, // the last agent that used it
	who_claude:    bool, // ... a Claude tab (caller panel + claude)
	doing:         Agent_Doing,
	last:          time.Tick, // its last command ({} = none, or Stop)
	want_console:  bool, // recording asked for (until capture_until)
	want_net:      bool,
	on_console:    bool, // Runtime + Log enabled in browser cap_cef
	on_net:        bool, // Network enabled
	cap_cef:       c.int,
	capture_until: time.Tick,
	capture_origin: string, // owned: the document's origin when it started ("" = a blank page's: the next page's)
	cap_next:      time.Tick, // a failed Runtime/Log/Network call: when to send it again
	logs:          [dynamic]Agent_Log,
	net:           [dynamic]Agent_Net,
	seq:           u64,
	nav_at:        time.Tick, // a navigation command (a load wait waits for its document)
	navigated_at:  time.Tick, // the top frame's last new document
	wake:          bool, // shown to CEF (not the user) for a screenshot
	shots:         u64,
	stops:         int, // Stop pressed (tests)
	sent:          map[string]int, // CDP methods sent (tests: no Runtime.enable before it is asked for)
	user_control:  bool, // Take over (or the user's input while an agent acted): agents wait for Hand back
	control_at:    time.Tick, // the last Take over or Hand back (its button ignores clicks for BARS_GUARD)
	act_target:    string, // owned: what the running action targets (the strip's 'Buy'; page data)
	mark_at:       time.Tick, // a click's ring (browser_act_draw), at the page's CSS px
	mark_x:        f32,
	mark_y:        f32,
}

Agent_Op_Kind :: enum u8 {
	Read,
	Wait,
	Shot,
}
Agent_Wait_For :: enum u8 {
	Load,
	Selector,
	Text,
}
Agent_Op :: struct {
	request_id: u64,
	tab_id:     u64,
	kind:       Agent_Op_Kind,
	mode:       string, // owned
	selector:   string, // owned
	value:      string, // owned
	max:        int,
	wait_for:   Agent_Wait_For,
	started:    time.Tick,
	deadline:   time.Tick,
	next_try:   time.Tick,
	msg_id:     c.int, // a CDP call in flight (0 = none)
	cef:        c.int, // the browser it went to
	reply:      string, // owned: its result ("" = none yet)
	reply_ok:   bool,
	rect:       App_Rect,
	has_rect:   bool,
	shot_seq:   u64, // the frame seq when the shot's frame was asked for (woken or painted again)
	woke:       bool,
	checked:    bool, // a shot: no revealed password shows (browser_act.js revealed)
}

AGENT_SHOT_NO_WORLD_MS :: 1000 // a screenshot waits this long for our world (its password check), then takes the page as is

agent_tabs: map[u64]^Agent_Tab
agent_ops: [dynamic]^Agent_Op
@(private = "file")
next_msg: c.int = AGENT_MSG_BASE
@(private = "file")
pruned: bool // old screenshots removed once per run

agent_tab_of :: proc(tab_id: u64) -> ^Agent_Tab {return agent_tabs[tab_id] or_else nil}

agent_tab :: proc(tab_id: u64) -> ^Agent_Tab {
	if t := agent_tabs[tab_id]; t != nil do return t
	t := new(Agent_Tab)
	t.tab_id = tab_id
	agent_tabs[tab_id] = t
	return t
}

// Whether CEF should paint this hidden tab (a screenshot waits for its frame): browser.odin.
browser_agent_wakes :: proc(tab_id: u64) -> bool {
	t := agent_tabs[tab_id] or_else nil
	return t != nil && t.wake
}

// ---- pure ----

// browser_read's max, clamped.
agent_read_max :: proc(max: int) -> int {
	if max <= 0 do return AGENT_READ_MAX
	return clamp(max, 100, AGENT_READ_LIMIT)
}

// browser_wait's timeout, clamped.
agent_wait_timeout :: proc(ms: int) -> time.Duration {
	if ms <= 0 do return AGENT_WAIT_DEFAULT
	return min(time.Duration(ms) * time.Millisecond, AGENT_WAIT_LIMIT)
}

// Selectors an agent may use: an outline's `ref=eN`, or simple CSS: compound parts (an optional
// tag name, then #ids and .classes) joined by spaces or `>`. Nothing that matches on attributes,
// state or position (no [..], :.., ::.., *, |, ",", +, ~, escapes or comments), so no selector
// can ask about a field's value however it is spelled.
AGENT_SELECTOR_UNSUPPORTED :: `only simple selectors: tag names, #ids and .classes, joined by spaces or > (e.g. "main article p", "div.card > a#buy"), or an outline's ref (e.g. "ref=e12"); no attributes, pseudo-classes, escapes, commas, *, + or ~`

agent_selector_ok :: proc(sel: string) -> bool {
	s := strings.trim(sel, " ")
	if s == "" do return false
	if strings.has_prefix(s, "ref=e") {
		n := s[len("ref=e"):]
		if n == "" do return false
		for ch in transmute([]u8)n do if ch < '0' || ch > '9' do return false
		return true
	}
	letter :: proc(ch: u8) -> bool {return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z')}
	digit :: proc(ch: u8) -> bool {return ch >= '0' && ch <= '9'}
	i := 0
	for {
		// one compound: [tag] (#ident | .ident)*
		start := i
		if i < len(s) && letter(s[i]) {
			for i < len(s) && (letter(s[i]) || digit(s[i]) || s[i] == '-') do i += 1
		}
		for i < len(s) && (s[i] == '#' || s[i] == '.') {
			i += 1
			// ident: not empty, not starting with a digit, "--" or "-" and a digit
			if i >= len(s) do return false
			if digit(s[i]) do return false
			if s[i] == '-' && (i + 1 >= len(s) || s[i + 1] == '-' || digit(s[i + 1])) do return false
			k := i
			for i < len(s) && (letter(s[i]) || digit(s[i]) || s[i] == '-' || s[i] == '_') do i += 1
			if i == k do return false
		}
		if i == start do return false
		// then the end, or a combinator (spaces, `>`) and another compound
		spaces := 0
		for i < len(s) && s[i] == ' ' {i += 1; spaces += 1}
		if i == len(s) do return true
		if s[i] == '>' {
			i += 1
			for i < len(s) && s[i] == ' ' do i += 1
		} else if spaces == 0 do return false
	}
}

// A request's or log line's address for an agent: no user:pass@, and the values of secret-looking
// parameters masked as *** (names kept): in the query and the fragment (a hash router's after its
// `?`), `&` or `;` separated, a name that (lower case, %-decoded) contains one of
// AGENT_SECRET_PARTS or starts with x-amz- / x-goog-.
AGENT_SECRET_PARTS :: [?]string{"token", "secret", "sig", "key", "pass", "auth", "session", "credential", "saml", "code", "state", "ticket", "jwt"}

agent_param_secret :: proc(name: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(name); i += 1 {
		ch := name[i]
		if ch == '%' && i + 2 < len(name) {
			if v, ok := strconv.parse_uint(name[i + 1:i + 3], 16); ok {
				ch = u8(v)
				i += 2
			}
		}
		strings.write_byte(&b, ch >= 'A' && ch <= 'Z' ? ch + 32 : ch)
	}
	n := strings.to_string(b)
	if strings.has_prefix(n, "x-amz-") || strings.has_prefix(n, "x-goog-") do return true
	for p in AGENT_SECRET_PARTS do if strings.contains(n, p) do return true
	return false
}

agent_url_masked :: proc(url: string) -> string {
	u := browser_url_public(url)
	q := strings.index_any(u, "?#")
	if q < 0 do return u
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, u[:q])
	params :: proc(b: ^strings.Builder, part: string) {
		start := 0
		for i := 0; i <= len(part); i += 1 {
			if i < len(part) && part[i] != '&' && part[i] != ';' do continue
			kv := part[start:i]
			if eq := strings.index_byte(kv, '='); eq >= 0 && eq + 1 < len(kv) && agent_param_secret(kv[:eq]) {
				strings.write_string(b, kv[:eq + 1])
				strings.write_string(b, "***")
			} else do strings.write_string(b, kv)
			if i < len(part) do strings.write_byte(b, part[i])
			start = i + 1
		}
	}
	rest := u[q:]
	if rest[0] == '?' {
		end := len(rest)
		if k := strings.index_byte(rest, '#'); k >= 0 do end = k
		strings.write_byte(&b, '?')
		params(&b, rest[1:end])
		rest = rest[end:]
	}
	if len(rest) > 0 {
		// the fragment: a hash router's `#/path?query`, `#a=1&b=2`, or an anchor
		frag := rest[1:]
		strings.write_byte(&b, '#')
		if k := strings.index_byte(frag, '?'); k >= 0 {
			strings.write_string(&b, frag[:k + 1])
			params(&b, frag[k + 1:])
		} else if strings.contains(frag, "=") do params(&b, frag)
		else do strings.write_string(&b, frag)
	}
	return strings.to_string(b)
}

// Text with the http(s) addresses in it masked as agent_url_masked does (console messages).
agent_text_masked :: proc(text: string) -> string {
	if !strings.contains(text, "http://") && !strings.contains(text, "https://") do return text
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(text) {
		k := -1
		for p in ([]string{"https://", "http://"}) {
			if x := strings.index(text[i:], p); x >= 0 && (k < 0 || x < k) do k = x
		}
		if k < 0 do break
		strings.write_string(&b, text[i:i + k])
		start := i + k
		end := start
		for end < len(text) && !strings.contains_rune(" \t\r\n\"'<>`)]}", rune(text[end])) do end += 1
		strings.write_string(&b, agent_url_masked(text[start:end]))
		i = end
	}
	strings.write_string(&b, text[i:])
	return strings.to_string(b)
}

// The CDP calls that bring the recording to what is wanted (in order), and the new on-state.
agent_capture_calls :: proc(want_console, want_net, on_console, on_net: bool) -> (calls: [dynamic]string, console, net: bool) {
	calls = make([dynamic]string, context.temp_allocator)
	if want_console && !on_console do append(&calls, "Runtime.enable", "Log.enable")
	if !want_console && on_console do append(&calls, "Runtime.disable", "Log.disable")
	if want_net && !on_net do append(&calls, "Network.enable")
	if !want_net && on_net do append(&calls, "Network.disable")
	return calls, want_console, want_net
}

// An address's origin (scheme://host:port; file: and others: their scheme), lower case.
agent_origin :: proc(url: string) -> string {
	i := strings.index(url, "://")
	if i < 0 {
		if k := strings.index_byte(url, ':'); k > 0 do return strings.to_lower(url[:k + 1], context.temp_allocator)
		return ""
	}
	start := i + 3
	end := len(url)
	if k := strings.index_any(url[start:], "/?#"); k >= 0 do end = start + k
	host := url[start:end]
	if at := strings.last_index_byte(host, '@'); at >= 0 do host = host[at + 1:]
	return strings.to_lower(strings.concatenate({url[:start], host}, context.temp_allocator), context.temp_allocator)
}

// Who the strip names.
agent_who :: proc(k: Caller_Kind, claude := false) -> string {
	#partial switch k {
	case .Panel:   return claude ? "Claude" : "pi"
	case .Control: return agent_name()
	}
	return "An agent"
}

// ---- commands ----

browser_agent_apply :: proc(cmd: Command, caller: Caller, request_id: u64) -> (r: Result, changed: bool) {
	#partial switch c in cmd {
	case Browser_Tabs:
		return agent_tabs_list(caller, c.session), false
	case Browser_Read:
		_, _, _, err := browser_target(caller, c.tab_id)
		if err != "" do return fail(err), false
		if r, refused := browser_agent_refused(caller, c.tab_id); refused do return r, false
		switch c.mode {
		case "", "text", "outline", "html":
		case: return fail("mode is text, outline or html"), false
		}
		if c.selector != "" && !agent_selector_ok(c.selector) do return {error = AGENT_SELECTOR_UNSUPPORTED, data = `{"code":"selector_unsupported"}`}, false
		op := agent_op(c.tab_id, request_id, .Read, AGENT_READ_TIMEOUT)
		op.mode = strings.clone(c.mode != "" ? c.mode : "text")
		op.selector = strings.clone(c.selector)
		op.max = agent_read_max(c.max)
		agent_touch(c.tab_id, caller, .Reading)
		return {ok = true, pending = true}, true
	case Browser_Page_Wait:
		_, _, _, err := browser_target(caller, c.tab_id)
		if err != "" do return fail(err), false
		if r, refused := browser_agent_refused(caller, c.tab_id); refused do return r, false
		w: Agent_Wait_For
		switch c.what {
		case "", "load": w = .Load
		case "selector": w = .Selector
		case "text":     w = .Text
		case: return fail(`for is load, selector or text`), false
		}
		if w != .Load && c.value == "" do return fail("value is needed (the selector or the text)"), false
		if w == .Selector && !agent_selector_ok(c.value) do return {error = AGENT_SELECTOR_UNSUPPORTED, data = `{"code":"selector_unsupported"}`}, false
		op := agent_op(c.tab_id, request_id, .Wait, agent_wait_timeout(c.timeout_ms))
		op.wait_for = w
		op.selector = strings.clone(w == .Selector ? c.value : "")
		op.value = strings.clone(w == .Text ? c.value : "")
		agent_touch(c.tab_id, caller, .Waiting)
		return {ok = true, pending = true}, true
	case Browser_Screenshot:
		_, _, _, err := browser_target(caller, c.tab_id)
		if err != "" do return fail(err), false
		if r, refused := browser_agent_refused(caller, c.tab_id); refused do return r, false
		if c.has_rect && (c.rect.w <= 0 || c.rect.h <= 0) do return {error = "rect needs a width and a height", data = `{"code":"bad_args"}`}, false
		op := agent_op(c.tab_id, request_id, .Shot, AGENT_SHOT_TIMEOUT)
		op.rect, op.has_rect = c.rect, c.has_rect
		agent_touch(c.tab_id, caller, .Reading)
		return {ok = true, pending = true}, true
	case Browser_Console, Browser_Network:
		console := false
		tab_id, since: u64
		limit: int
		if x, is := cmd.(Browser_Console); is {
			console, tab_id, since, limit = true, x.tab_id, x.since, x.limit
		} else if x, is := cmd.(Browser_Network); is {
			tab_id, since, limit = x.tab_id, x.since, x.limit
		}
		_, _, _, err := browser_target(caller, tab_id)
		if err != "" do return fail(err), false
		if r, refused := browser_agent_refused(caller, tab_id); refused do return r, false
		t := agent_tab(tab_id)
		started := console ? !t.want_console : !t.want_net
		if console do t.want_console = true
		else do t.want_net = true
		t.capture_until = time.tick_add(time.tick_now(), AGENT_CAPTURE_FOR)
		if started {
			_, tab, _ := find_tab(tab_id)
			// a blank page has none yet: the first real page's is taken (devtools, Page.frameNavigated)
			if bt, is := tab.kind.(Browser_Tab); is do set_owned(&t.capture_origin, agent_real_origin(bt.url))
		}
		agent_touch(tab_id, caller, .Reading)
		return {ok = true, data = agent_log_json(t, console, since, limit, started)}, true
	case Browser_Comments:
		return agent_comments(caller, c.tab_id, c.session), false
	case Browser_Agent_Stop:
		_, _, _, err := browser_target(caller, c.tab_id)
		if err != "" do return fail(err), false
		return {ok = true}, agent_stop(c.tab_id)
	}
	return fail("not a browser agent command"), false
}

// The navigation commands (browser_nav.odin), once they ran: an agent's shows the strip; any
// navigation makes a load wait wait for the new document.
browser_agent_nav_ran :: proc(cmd: Command, caller: Caller, r: Result) {
	if !r.ok do return
	tab_id := browser_command_tab(cmd)
	#partial switch _ in cmd {
	case Browser_Open:     tab_id = r.created_id
	case Browser_Update:   return
	}
	if tab_id == 0 do return
	#partial switch _ in cmd {
	case Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload:
		agent_tab(tab_id).nav_at = time.tick_now()
	case Browser_Open:
		// an agent's: the new tab's first document (blank) is "complete" before its page's. Only an
		// agent's: the agent state (and its strip) is made for an agent's tab, not the user's
		if caller.kind == .Panel || caller.kind == .Control do agent_tab(tab_id).nav_at = time.tick_now()
	}
	agent_touch(tab_id, caller, .Driving)
}

agent_touch :: proc(tab_id: u64, caller: Caller, doing: Agent_Doing) {
	if caller.kind != .Panel && caller.kind != .Control do return // the user's own and scripts': no strip
	t := agent_tab(tab_id)
	t.who, t.who_claude, t.doing, t.last = caller.kind, caller.claude, doing, time.tick_now()
	app.redraw = true
}

@(private = "file")
agent_op :: proc(tab_id, request_id: u64, kind: Agent_Op_Kind, timeout: time.Duration) -> ^Agent_Op {
	op := new(Agent_Op)
	now := time.tick_now()
	op^ = {request_id = request_id, tab_id = tab_id, kind = kind, started = now, deadline = time.tick_add(now, timeout)}
	append(&agent_ops, op)
	app.redraw = true
	return op
}

@(private = "file")
op_free :: proc(op: ^Agent_Op) {
	delete(op.mode)
	delete(op.selector)
	delete(op.value)
	delete(op.reply)
	free(op)
}

@(private = "file")
set_owned :: proc(dst: ^string, v: string) {
	if dst^ == v do return
	delete(dst^)
	dst^ = strings.clone(v)
}

// Stop (the strip's button): the tab's agent commands in flight end (its actions, running and
// queued, too: browser_act.odin), its recording stops.
@(private = "file")
agent_stop :: proc(tab_id: u64) -> bool {
	t := agent_tab(tab_id)
	t.stops += 1
	t.last = {}
	t.want_console, t.want_net = false, false
	agent_forget(t)
	STOPPED :: "stopped by the user (Stop on the page's agent strip)"
	agent_ops_end(tab_id, STOPPED, "stopped")
	browser_act_cancel(tab_id, STOPPED, "stopped")
	agent_unwake(tab_id)
	app.redraw = true
	return true
}

// Every agent command in flight on the tab ends with this error.
@(private = "file")
agent_ops_end :: proc(tab_id: u64, msg, code: string) {
	for i := len(agent_ops) - 1; i >= 0; i -= 1 {
		op := agent_ops[i]
		if op.tab_id != tab_id do continue
		act_finish(op.request_id, {error = msg, data = fmt.tprintf(`{{"code":"%s"}}`, code)})
		ordered_remove(&agent_ops, i)
		op_free(op)
	}
}

// The agent command with this request id ends with code (its requester cancelled): true if one ran.
agent_request_end :: proc(request_id: u64, msg, code: string) -> bool {
	for op, i in agent_ops do if op.request_id == request_id {
		act_finish(op.request_id, {error = msg, data = fmt.tprintf(`{{"code":"%s"}}`, code)})
		ordered_remove(&agent_ops, i)
		tab_id := op.tab_id
		op_free(op)
		agent_unwake(tab_id)
		app.redraw = true
		return true
	}
	return false
}

// Take over (the strip's button, or the user's own click or key while an agent acted): every
// agent command and action on the tab ends with user_has_control, and agents' calls are refused
// until Hand back (on = false).
agent_take_over :: proc(tab_id: u64, on: bool) {
	t := agent_tab(tab_id)
	if t.user_control != on do t.control_at = time.tick_now()
	t.user_control = on
	t.last = time.tick_now()
	if on {
		agent_ops_end(tab_id, ACT_USER_HAS_CONTROL, "user_has_control")
		browser_act_cancel(tab_id, ACT_USER_HAS_CONTROL, "user_has_control")
		agent_unwake(tab_id)
	}
	fmt.printfln("[browser] tab %d: %s", tab_id, on ? "the user took over (agents wait)" : "handed back to agents")
	app.redraw = true
}

// The agent state of the focused pane's page while its strip shows (the palette's Take over, Hand
// back and Stop: actions.odin).
browser_agent_shown :: proc() -> ^Agent_Tab {
	b := tab_browser()
	if b == nil do return nil
	t := agent_tab_of(b.tab_id)
	if t == nil || !agent_strip_on(t) do return nil
	return t
}

// The strip's Take over / Hand back takes a click: not within BARS_GUARD of the last toggle.
browser_agent_toggle_ok :: proc(tab_id: u64) -> bool {
	t := agent_tab_of(tab_id)
	return t == nil || t.control_at == {} || time.tick_since(t.control_at) >= BARS_GUARD
}

// An agent's call on a tab the user has taken over: refused at once (user_has_control).
browser_agent_refused :: proc(caller: Caller, tab_id: u64) -> (Result, bool) {
	if caller.kind != .Panel && caller.kind != .Control do return {}, false
	t := agent_tab_of(tab_id)
	if t == nil || !t.user_control do return {}, false
	return {error = ACT_USER_HAS_CONTROL, data = `{"code":"user_has_control"}`}, true
}

// The navigation commands (browser_nav.odin) on a tab the user has taken over: refused for agents.
browser_agent_nav_refused :: proc(cmd: Command, caller: Caller) -> (Result, bool) {
	#partial switch _ in cmd {
	case Browser_Navigate, Browser_Back, Browser_Forward, Browser_Reload, Browser_Stop:
		return browser_agent_refused(caller, browser_command_tab(cmd))
	}
	return {}, false
}

agent_unwake :: proc(tab_id: u64) {
	t := agent_tab_of(tab_id)
	if t == nil do return
	for op in agent_ops do if op.tab_id == tab_id && op.kind == .Shot do return
	if browser_act_waking(tab_id) do return
	t.wake = false
}

// browser_tabs: the caller's session's browser tabs (a pi tab's own; a control caller's named
// session, or every one).
@(private = "file")
agent_tabs_list :: proc(caller: Caller, session: u64) -> Result {
	want := session
	if caller.kind == .Panel {
		own := caller_session(caller)
		if own == nil do return fail("the calling pi tab has no session")
		if session != 0 && session != own.id do return fail("a pi tab sees only its own session's browser tabs")
		want = own.id
	} else if session != 0 && find_session(session) == nil do return fail("no such session")
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"tabs":[`)
	n := 0
	for s in state.open_sessions {
		if want != 0 && s.id != want do continue
		for tab in s.tabs {
			bt, is := tab.kind.(Browser_Tab)
			if !is do continue
			if n > 0 do strings.write_byte(&b, ',')
			n += 1
			br := browser_of(tab.id)
			page := br == nil ? "closed" : br.cef != 0 ? "open" : br.waiting ? "waiting" : br.lazy ? "unloaded" : br.message != "" ? "closed" : "opening"
			fmt.sbprintf(&b, `{{"tab_id":%d,"session":%d,"title":`, tab.id, s.id)
			json_quote(&b, tab.title)
			strings.write_string(&b, `,"url":`)
			json_quote(&b, bt.url)
			on_screen := tab_on_screen(tab.id) // shown in a pane of the session on screen (panes.odin)
			comments := 0
			for cm in s.comments do if cm.tab_id == tab.id do comments += 1
			fmt.sbprintf(&b, `,"loading":%v,"page":"%s","on_screen":%v,"comments":%d`, bt.loading, page, on_screen, comments)
			if t := agent_tab_of(tab.id); t != nil && (t.want_console || t.want_net) do fmt.sbprintf(&b, `,"recording":"%s"`, t.want_console && t.want_net ? "console,network" : t.want_console ? "console" : "network")
			strings.write_byte(&b, '}')
		}
	}
	strings.write_string(&b, "]}")
	return {ok = true, data = strings.to_string(b)}
}

// browser_comments: the session's pending comments (only tab_id's, if given), not consumed.
@(private = "file")
agent_comments :: proc(caller: Caller, tab_id, session: u64) -> Result {
	s: ^Open_Session
	if tab_id != 0 {
		ts, tab, _ := find_tab(tab_id)
		if tab == nil do return fail("no such tab")
		if caller.kind == .Panel && caller_session(caller) != ts do return fail("a pi tab sees only its own session's comments")
		s = ts
	} else if caller.kind == .Panel {
		s = caller_session(caller)
		if session != 0 && (s == nil || s.id != session) do return fail("a pi tab sees only its own session's comments")
	} else {
		s = session != 0 ? find_session(session) : caller.kind == .Control ? nil : cur()
		if s == nil do return fail(session != 0 ? "no such session" : "session or tab_id is needed")
	}
	if s == nil do return fail("no such session")
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"session":%d,"comments":[`, s.id)
	n := 0
	for cm, i in s.comments {
		if tab_id != 0 && cm.tab_id != tab_id do continue
		if n > 0 do strings.write_byte(&b, ',')
		n += 1
		fmt.sbprintf(&b, `{{"comment_id":%d,"n":%d,"source":"%s","tab_id":%d,"what":`, cm.id, i + 1, COMMENT_SOURCE_NAMES[cm.source], cm.tab_id)
		json_quote(&b, cm.what)
		strings.write_string(&b, `,"text":`)
		json_quote(&b, cm.text)
		fmt.sbprintf(&b, `,"has_crop":%v}}`, cm.crop != "")
	}
	strings.write_string(&b, "]}")
	return {ok = true, data = strings.to_string(b)}
}

// browser_console / browser_network's answer: entries after since (at most limit), the cursor,
// and the recording's state.
@(private = "file")
agent_log_json :: proc(t: ^Agent_Tab, console: bool, since: u64, limit: int, started: bool) -> string {
	lim := limit > 0 ? min(limit, AGENT_LOG_MAX) : 100
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, `{{"recording":{{"on":true,"started_now":%v,"for_s":%d}},"entries":[`, started, int(time.duration_seconds(AGENT_CAPTURE_FOR)))
	n := 0
	next := since
	if console {
		for e in t.logs {
			if e.seq <= since do continue
			if n >= lim do break
			if n > 0 do strings.write_byte(&b, ',')
			n += 1
			next = max(next, e.seq)
			fmt.sbprintf(&b, `{{"seq":%d,"level":`, e.seq)
			json_quote(&b, e.level)
			strings.write_string(&b, `,"text":`)
			json_quote(&b, e.text)
			if e.source != "" {
				strings.write_string(&b, `,"source":`)
				json_quote(&b, e.source)
			}
			strings.write_byte(&b, '}')
		}
	} else {
		// by seq (an entry's seq moves when its response arrives)
		order := make([dynamic]^Agent_Net, context.temp_allocator)
		for &e in t.net do if e.seq > since do append(&order, &e)
		for a in 1 ..< len(order) do for k := a; k > 0 && order[k].seq < order[k - 1].seq; k -= 1 do order[k], order[k - 1] = order[k - 1], order[k]
		for e in order {
			if n >= lim do break
			if n > 0 do strings.write_byte(&b, ',')
			n += 1
			next = max(next, e.seq)
			fmt.sbprintf(&b, `{{"seq":%d,"method":`, e.seq)
			json_quote(&b, e.method)
			strings.write_string(&b, `,"url":`)
			json_quote(&b, e.url)
			strings.write_string(&b, `,"type":`)
			json_quote(&b, e.kind)
			if e.status != 0 do fmt.sbprintf(&b, `,"status":%d`, e.status)
			if e.mime != "" {
				strings.write_string(&b, `,"mime":`)
				json_quote(&b, e.mime)
			}
			if e.failed != "" {
				strings.write_string(&b, `,"failed":`)
				json_quote(&b, e.failed)
			}
			fmt.sbprintf(&b, `,"done":%v}}`, e.done)
		}
	}
	fmt.sbprintf(&b, `],"next":%d}}`, next)
	return strings.to_string(b)
}

// ---- the DevTools protocol (browser_annotate.odin's observer hands every message here first) ----

cdp_send :: proc(t: ^Agent_Tab, cef: c.int, method, params: string) -> c.int {
	if cef == 0 do return 0
	next_msg += 1
	if next_msg < AGENT_MSG_BASE do next_msg = AGENT_MSG_BASE + 1 // wrapped
	id := next_msg
	msg := fmt.tprintf(`{{"id":%d,"method":"%s","params":%s}}`, id, method, params)
	if dh_cef_devtools_send(cef, raw_data(msg), c.size_t(len(msg))) == 0 do return 0
	if autotest.active && t != nil {
		if _, has := t.sent[method]; !has do t.sent[strings.clone(method)] = 0
		t.sent[method] += 1
	}
	return id
}

// Our results (consumed: true) and the events we follow (Page.frameNavigated, the recording's).
browser_agent_devtools :: proc(cef: c.int, msg_id: c.int, ok: c.int, method: cstring, data: [^]u8, n: c.size_t) -> bool {
	if msg_id >= AGENT_MSG_BASE {
		for op in agent_ops do if op.msg_id == msg_id && op.cef == cef {
			op.msg_id = 0
			delete(op.reply)
			op.reply = strings.clone(string(data[:n]))
			op.reply_ok = ok != 0
			if op.reply == "" do op.reply = strings.clone("{}")
			return true
		}
		browser_act_devtools(cef, msg_id, ok, data, n) // an action's (browser_act.odin), or one nobody waits for
		return true
	}
	if msg_id != 0 do return false
	m := string(method)
	if m != "Page.frameNavigated" && !strings.has_prefix(m, "Runtime.") && !strings.has_prefix(m, "Log.") && !strings.has_prefix(m, "Network.") do return false
	b: ^Browser
	for _, x in browsers do if x.cef == cef do b = x
	if b == nil do return false
	t := agent_tab_of(b.tab_id)
	if t == nil do return false
	if m == "Page.frameNavigated" {
		v, err := jg.parse(data[:n], .JSON, true, context.temp_allocator)
		if err != nil do return false
		frame, _ := v.(json.Object)["frame"].(json.Object)
		if _, sub := frame["parentId"]; sub do return false
		t.navigated_at = time.tick_now()
		// recording ends on another origin (the agent asked about the site it was on)
		// (and what it recorded goes: the redirect that led here, e.g. an OAuth code, included)
		if t.want_console || t.want_net {
			u, _ := frame["url"].(json.String)
			o := agent_real_origin(u)
			if t.capture_origin == "" do set_owned(&t.capture_origin, o)
			else if o != t.capture_origin {
				t.want_console, t.want_net = false, false
				agent_forget(t)
				app.redraw = true
			}
		}
		return false
	}
	// on and still wanted (after a cutoff the domains stay on until the next tick turns them off)
	con, net := t.on_console && t.want_console, t.on_net && t.want_net
	if t.cap_cef != cef || !(con || net) do return false
	v, err := jg.parse(data[:n], .JSON, true, context.temp_allocator)
	if err != nil do return false
	o, _ := v.(json.Object)
	switch m {
	case "Runtime.consoleAPICalled":
		if !con do break
		args, _ := o["args"].(json.Array)
		sb := strings.builder_make(context.temp_allocator)
		for a, i in args {
			if i > 0 do strings.write_byte(&sb, ' ')
			strings.write_string(&sb, remote_text(a))
			if strings.builder_len(sb) > AGENT_TEXT_MAX do break
		}
		level, _ := o["type"].(json.String)
		log_add(t, level, strings.to_string(sb), frame_source(o["stackTrace"]))
	case "Runtime.exceptionThrown":
		if !con do break
		d, _ := o["exceptionDetails"].(json.Object)
		text, _ := d["text"].(json.String)
		if ex, is := d["exception"].(json.Object); is {
			if desc, ok2 := ex["description"].(json.String); ok2 do text = desc
		}
		url, _ := d["url"].(json.String)
		line, _ := d["lineNumber"].(json.Integer)
		log_add(t, "exception", text, url != "" ? fmt.tprintf("%s:%d", agent_url_masked(url), line + 1) : "")
	case "Log.entryAdded":
		if !con do break
		e, _ := o["entry"].(json.Object)
		level, _ := e["level"].(json.String)
		text, _ := e["text"].(json.String)
		src, _ := e["source"].(json.String)
		url, _ := e["url"].(json.String)
		log_add(t, fmt.tprintf("%s (%s)", level, src), text, url != "" ? agent_url_masked(url) : "")
	case "Network.requestWillBeSent":
		if !net do break
		req, _ := o["request"].(json.Object)
		id, _ := o["requestId"].(json.String)
		method, _ := req["method"].(json.String)
		url, _ := req["url"].(json.String)
		kind, _ := o["type"].(json.String)
		if len(t.net) >= AGENT_LOG_MAX do net_drop(t, 0)
		t.seq += 1
		append(&t.net, Agent_Net{seq = t.seq, id = strings.clone(id), method = strings.clone(cut_utf8(method, 20)), url = strings.clone(cut_utf8(agent_url_masked(url), AGENT_URL_MAX)), kind = strings.clone(cut_utf8(kind, 40))})
	case "Network.responseReceived", "Network.loadingFailed", "Network.loadingFinished":
		if !net do break
		id, _ := o["requestId"].(json.String)
		for &e in t.net do if e.id == id {
			switch m {
			case "Network.responseReceived":
				r, _ := o["response"].(json.Object)
				if st, ok2 := num_i(r["status"]); ok2 do e.status = st
				mime, _ := r["mimeType"].(json.String)
				set_owned(&e.mime, cut_utf8(mime, 100))
			case "Network.loadingFailed":
				et, _ := o["errorText"].(json.String)
				set_owned(&e.failed, cut_utf8(et != "" ? et : "failed", 200))
				e.done = true
			case "Network.loadingFinished":
				e.done = true
			}
			t.seq += 1
			e.seq = t.seq
		}
	}
	return false

	num_i :: proc(v: json.Value) -> (int, bool) {
		#partial switch x in v {
		case json.Integer: return int(x), true
		case json.Float:   return int(x), true
		}
		return 0, false
	}
	// a console argument as text: a primitive's value, else the object's description
	remote_text :: proc(v: json.Value) -> string {
		o, _ := v.(json.Object)
		#partial switch x in o["value"] {
		case json.String:  return x
		case json.Integer: return fmt.tprint(x)
		case json.Float:   return fmt.tprint(x)
		case json.Boolean: return x ? "true" : "false"
		case json.Null:    return "null"
		}
		if s, ok := o["unserializableValue"].(json.String); ok do return s
		if s, ok := o["description"].(json.String); ok do return s
		if s, ok := o["type"].(json.String); ok do return s
		return ""
	}
	frame_source :: proc(v: json.Value) -> string {
		st, _ := v.(json.Object)
		frames, _ := st["callFrames"].(json.Array)
		if len(frames) == 0 do return ""
		f, _ := frames[0].(json.Object)
		url, _ := f["url"].(json.String)
		line, _ := f["lineNumber"].(json.Integer)
		if url == "" do return ""
		return fmt.tprintf("%s:%d", agent_url_masked(url), line + 1)
	}
}

@(private = "file")
log_add :: proc(t: ^Agent_Tab, level, text, source: string) {
	if len(t.logs) >= AGENT_LOG_MAX {
		e := t.logs[0]
		delete(e.level)
		delete(e.text)
		delete(e.source)
		ordered_remove(&t.logs, 0)
	}
	t.seq += 1
	append(&t.logs, Agent_Log{seq = t.seq, level = strings.clone(cut_utf8(level, 40)), text = strings.clone(cut_utf8(agent_text_masked(text), AGENT_TEXT_MAX)), source = strings.clone(cut_utf8(source, AGENT_URL_MAX))})
}

// The recording's entries go (it ended: Stop, expiry, another origin); seq keeps counting.
@(private = "file")
agent_forget :: proc(t: ^Agent_Tab) {
	for e in t.logs {
		delete(e.level)
		delete(e.text)
		delete(e.source)
	}
	clear(&t.logs)
	for len(t.net) > 0 do net_drop(t, len(t.net) - 1)
}

// An address's origin, "" for a blank page (about:, an empty address).
agent_real_origin :: proc(url: string) -> string {
	o := agent_origin(url)
	return o == "about:" ? "" : o
}

@(private = "file")
net_drop :: proc(t: ^Agent_Tab, i: int) {
	e := t.net[i]
	delete(e.id)
	delete(e.method)
	delete(e.url)
	delete(e.kind)
	delete(e.mime)
	delete(e.failed)
	ordered_remove(&t.net, i)
}

@(private = "file")
agent_tab_free :: proc(t: ^Agent_Tab) {
	for len(t.logs) > 0 {
		e := t.logs[0]
		delete(e.level)
		delete(e.text)
		delete(e.source)
		ordered_remove(&t.logs, 0)
	}
	delete(t.logs)
	for len(t.net) > 0 do net_drop(t, 0)
	delete(t.net)
	delete(t.capture_origin)
	delete(t.act_target)
	for k in t.sent do delete(k)
	delete(t.sent)
	free(t)
}

// Every op and tab state gone, unanswered (unit tests: no page ever answers here).
browser_agent_reset :: proc() {
	for op in agent_ops do op_free(op)
	clear(&agent_ops)
	for _, t in agent_tabs do agent_tab_free(t)
	clear(&agent_tabs)
}

// ---- every frame (main.odin, before the redraw check) ----

// Ops step, recordings follow what is wanted; finished ops answer. True: redraw (an op waits for
// a page to open or its overlay, which the layout pass runs).
browser_agent_tick :: proc() -> bool {
	if len(agent_ops) == 0 && len(agent_tabs) == 0 do return false
	now := time.tick_now()
	redraw := false
	// closed tabs: their state goes
	gone := make([dynamic]u64, context.temp_allocator)
	for id in agent_tabs do if _, tab, _ := find_tab(id); tab == nil do append(&gone, id)
	for id in gone {
		agent_tab_free(agent_tabs[id])
		delete_key(&agent_tabs, id)
	}
	// recordings
	for id, t in agent_tabs {
		if (t.want_console || t.want_net) && time.tick_diff(t.capture_until, now) > 0 {
			t.want_console, t.want_net = false, false
			agent_forget(t)
			redraw = true
		}
		b := browser_of(id)
		cef := b != nil ? b.cef : 0
		if cef != t.cap_cef {
			// a new browser (or none): its domains are off
			t.cap_cef, t.on_console, t.on_net = cef, false, false
		}
		if cef == 0 do continue
		// a domain counts as on (off) once its calls went; a failed send is tried again shortly
		if (t.want_console != t.on_console || t.want_net != t.on_net) && time.tick_diff(t.cap_next, now) >= 0 {
			redraw = true // sent (or tried: tried again after AGENT_POLL)
			if t.want_console != t.on_console {
				calls, _, _ := agent_capture_calls(t.want_console, false, t.on_console, false)
				sent := true
				for m in calls do if cdp_send(t, cef, m, "{}") == 0 do sent = false
				if sent do t.on_console = t.want_console
				else do t.cap_next = time.tick_add(now, AGENT_POLL)
			}
			if t.want_net != t.on_net {
				calls, _, _ := agent_capture_calls(false, t.want_net, false, t.on_net)
				sent := true
				for m in calls do if cdp_send(t, cef, m, "{}") == 0 do sent = false
				if sent do t.on_net = t.want_net
				else do t.cap_next = time.tick_add(now, AGENT_POLL)
			}
		}
		// the strip fades after its linger
		if t.last != {} && time.tick_diff(t.last, now) > AGENT_STRIP_LINGER && !agent_busy(id) {
			t.last = {}
			redraw = true
		}
	}
	for i := 0; i < len(agent_ops); {
		op := agent_ops[i]
		done, r, private := op_step(op, now)
		if done {
			// pending: frame_shot's worker answers it
			if !r.pending do emit_event(Finished_Event{request_id = op.request_id, result = r, private = private})
			ordered_remove(&agent_ops, i)
			tab_id := op.tab_id
			op_free(op)
			agent_unwake(tab_id)
			if t := agent_tab_of(tab_id); t != nil && t.last != {} do t.last = now // lingers from the end
			redraw = true
			continue
		}
		if op.msg_id == 0 do redraw = true // waiting for the page or its overlay (layout pass)
		i += 1
	}
	return redraw
}

@(private = "file")
agent_busy :: proc(tab_id: u64) -> bool {
	for op in agent_ops do if op.tab_id == tab_id do return true
	return browser_act_busy(tab_id)
}

// One op's step: done, with its result (private: a page's content).
@(private = "file")
op_step :: proc(op: ^Agent_Op, now: time.Tick) -> (done: bool, r: Result, private: bool) {
	_, tab, _ := find_tab(op.tab_id)
	b := browser_of(op.tab_id)
	if tab == nil || b == nil do return true, {error = "the tab closed", data = `{"code":"tab_gone"}`}, false
	bt, _ := tab.kind.(Browser_Tab)
	late := time.tick_diff(op.deadline, now) > 0
	waited := int(time.duration_milliseconds(time.tick_diff(op.started, now)))
	// the page: an unloaded tab loads into a free slot (never another tab's); a closed one fails
	if b.cef == 0 {
		if b.lazy {
			b.lazy = false
			app.redraw = true
		}
		if b.message != "" && !b.waiting do return true, {error = fmt.tprintf("the page is not open: %s (browser_reload opens it again)", b.message), data = `{"code":"no_page"}`}, false
		if late do return true, {error = b.waiting ? "no page slot is free: too many open pages (the user's tabs keep theirs); close a browser tab or try later" : "the page did not open in time", data = b.waiting ? `{"code":"no_slot"}` : `{"code":"timeout"}`}, false
		return false, {}, false
	}
	if op.kind == .Shot && op.checked do return shot_step(op, b, now, late)
	a := annot_of(op.tab_id)
	ctx := a != nil && a.cef == b.cef ? a.ctx : 0
	t := agent_tab(op.tab_id)
	// an answer
	if op.reply != "" {
		reply, ok := op.reply, op.reply_ok
		defer {
			delete(op.reply)
			op.reply = ""
		}
		value, err := eval_value(reply, ok)
		if err != "" {
			// the document went while it ran (its context is gone): ask the new one, after the poll interval
			if !late {
				op.next_try = time.tick_add(now, AGENT_POLL)
				return false, {}, false
			}
			return true, {error = fmt.tprintf("the page did not answer: %s", err), data = `{"code":"page_error"}`}, false
		}
		v, perr := jg.parse_string(value, .JSON, true, context.temp_allocator)
		o, is := v.(json.Object)
		if perr != nil || !is do return true, {error = "the page's answer was not readable", data = `{"code":"page_error"}`}, false
		if e, has := o["error"].(json.String); has do return true, {error = e, data = `{"code":"bad_args"}`}, false
		switch op.kind {
		case .Read:
			// the page's address as everywhere else: secret-looking parameters masked
			if u, has := o["url"].(json.String); has {
				o["url"] = json.String(agent_url_masked(u))
				if out, merr := json.marshal(o, allocator = context.temp_allocator); merr == nil do return true, {ok = true, data = string(out)}, true
				return true, {error = "the page's answer was not readable", data = `{"code":"page_error"}`}, false
			}
			return true, {ok = true, data = value}, true
		case .Wait:
			met := false
			if f, has := o["found"].(json.Boolean); has do met = bool(f)
			if f, has := o["ready"].(json.Boolean); has do met = bool(f)
			if met do return true, {ok = true, data = fmt.tprintf(`{{"waited_ms":%d}}`, waited)}, false
			op.next_try = time.tick_add(now, AGENT_POLL)
		case .Shot:
			// a password field shown as text (its type flipped by "show password") with text in
			// it: no picture of the page while it shows
			n, _ := o["revealed"].(json.Integer)
			if n > 0 do return true, {error = "a password field on the page shows its text (a \"show password\" button was used): no screenshot while it shows. Ask the user to hide it, or to press Take over", data = `{"code":"sensitive_visible"}`}, false
			op.checked = true
			return shot_step(op, b, now, late)
		}
	}
	// a page without our world (a browser error page): no field to check, the picture as before
	if op.kind == .Shot && ctx == 0 && op.msg_id == 0 && waited >= AGENT_SHOT_NO_WORLD_MS {
		op.checked = true
		return shot_step(op, b, now, late)
	}
	if late {
		if op.kind == .Wait {
			what := op.wait_for == .Load ? "the page to load" : op.wait_for == .Selector ? "a visible element matching the selector" : "the text"
			return true, {error = fmt.tprintf("timed out after %d ms waiting for %s", waited, what), data = `{"code":"timeout"}`}, false
		}
		return true, {error = ctx == 0 ? "the page is not ready to be read (no document yet)" : "the page did not answer in time", data = `{"code":"timeout"}`}, false
	}
	if op.msg_id != 0 || ctx == 0 do return false, {}, false
	if time.tick_diff(op.next_try, now) < 0 do return false, {}, false
	mode, sel, value := op.mode, op.selector, op.value
	if op.kind == .Wait {
		switch op.wait_for {
		case .Load:
			// its document first (a navigation just asked for), then not loading, then complete
			if t.nav_at != {} && time.tick_diff(t.nav_at, t.navigated_at) < 0 && time.tick_diff(t.nav_at, now) < AGENT_NAV_SETTLE do return false, {}, false
			if bt.loading do return false, {}, false
			mode = "ready"
		case .Selector: mode = "has_selector"
		case .Text:     mode = "has_text"
		}
	}
	args := strings.builder_make(context.temp_allocator)
	if op.kind == .Shot {
		strings.write_string(&args, "(")
		strings.write_string(&args, BROWSER_ACT_JS)
		strings.write_string(&args, `)({"op":"revealed"})`)
	} else {
		strings.write_string(&args, "(")
		strings.write_string(&args, BROWSER_READ_JS)
		strings.write_string(&args, ")(")
		json_quote(&args, mode)
		strings.write_byte(&args, ',')
		json_quote(&args, sel)
		fmt.sbprintf(&args, ",%d,", op.max)
		json_quote(&args, value)
		strings.write_byte(&args, ')')
	}
	p := strings.builder_make(context.temp_allocator)
	strings.write_string(&p, `{"expression":`)
	json_quote(&p, strings.to_string(args))
	fmt.sbprintf(&p, `,"contextId":%d,"returnByValue":true,"silent":true}}`, ctx)
	op.cef = b.cef
	op.msg_id = cdp_send(t, b.cef, "Runtime.evaluate", strings.to_string(p))
	if op.msg_id == 0 do op.next_try = time.tick_add(now, AGENT_POLL) // not sent: again soon
	return false, {}, false

	// Runtime.evaluate's string result, or why not
	eval_value :: proc(reply: string, ok: bool) -> (string, string) {
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
		s, is := res["value"].(json.String)
		if !is do return "", "no value"
		return s, ""
	}
}

// A screenshot: a tab on screen paints again once its view's size settled (AGENT_SHOT_SETTLE)
// and that frame is taken; a tab not on screen is woken (CEF paints it; the user does not see
// it) and its next frame taken.
@(private = "file")
shot_step :: proc(op: ^Agent_Op, b: ^Browser, now: time.Tick, late: bool) -> (done: bool, r: Result, private: bool) {
	t := agent_tab(op.tab_id)
	on_screen := tab_on_screen(b.tab_id) // in any pane: it paints, the user sees it
	ready := b.ring.shown_gen != 0 && b.content_w > 0
	if !on_screen {
		if !op.woke {
			op.woke = true
			op.shot_seq = b.ring.shown_seq
			t.wake = true
			dh_cef_invalidate(b.cef)
			app.redraw = true
		}
		ready = ready && b.ring.shown_seq > op.shot_seq
	} else {
		// the view's size settled (resized and painted at least AGENT_SHOT_SETTLE ago), then a
		// frame painted after that; once late, the frame there is
		settled := time.tick_diff(b.resized_at, now) >= AGENT_SHOT_SETTLE && time.tick_diff(b.paint_since, now) >= AGENT_SHOT_SETTLE
		if !settled && !late do return false, {}, false
		if !op.woke && !late {
			op.woke = true
			op.shot_seq = b.ring.shown_seq
			dh_cef_invalidate(b.cef)
			app.redraw = true
		}
		if !late do ready = ready && b.ring.shown_seq > op.shot_seq
	}
	if !ready {
		if late do return true, {error = "the page has painted no frame yet", data = `{"code":"no_frame"}`}, false
		return false, {}, false
	}
	g := ring_gen(&b.ring, b.ring.shown_gen)
	if g == nil do return true, {error = "the page has painted no frame yet", data = `{"code":"no_frame"}`}, false
	x, y, w, h, ok := app_shot_rect(op.rect, op.has_rect, g.scale, b.content_w, b.content_h)
	if !ok do return true, {error = "the rect is outside the page", data = `{"code":"bad_args"}`}, false
	if !pruned {
		pruned = true
		app_shots_prune(app_shots_dir(context.temp_allocator), 24 * time.Hour)
	}
	t.shots += 1
	meta := fmt.tprintf(`"scale":%.2f,"rect":{{"x":%d,"y":%d,"w":%d,"h":%d}},"on_screen":%v`, g.scale, x, y, w, h, on_screen)
	res := frame_shot(op.tab_id, g.gen, b.ring.shown_slot, x, y, w, h, t.shots, meta, op.request_id)
	if res.pending {
		// frame_shot's worker finishes the request; this op is done
		return true, res, false
	}
	return true, res, false
}

// ---- State (json_write.odin, inside a browser tab's object) ----

// `,"agent":{who, doing, busy, recording}` while the strip shows.
browser_agent_tab_json :: proc(b: ^strings.Builder, tab_id: u64) {
	t := agent_tab_of(tab_id)
	if t == nil || !agent_strip_on(t) do return
	strings.write_string(b, `,"agent":{"who":`)
	json_quote(b, agent_who(t.who, t.who_claude))
	fmt.sbprintf(b, `,"doing":"%s","busy":%v,"recording":"%s"`, AGENT_DOING_NAMES[t.doing], agent_busy(tab_id), recording(t))
	if t.act_target != "" {
		strings.write_string(b, `,"target":`)
		json_quote(b, t.act_target)
	}
	if browser_act_busy(tab_id) do strings.write_string(b, `,"acting":true`)
	if t.user_control do strings.write_string(b, `,"control":"user"`)
	strings.write_byte(b, '}')
}

@(private = "file")
recording :: proc(t: ^Agent_Tab) -> string {
	return t.want_console && t.want_net ? "console,network" : t.want_console ? "console" : t.want_net ? "network" : ""
}

@(private = "file")
agent_strip_on :: proc(t: ^Agent_Tab) -> bool {
	return t.last != {} || agent_busy(t.tab_id) || t.want_console || t.want_net || t.user_control
}

// ---- the strip (browser_nav.odin's toolbar) ----

// "pi is reading this page · Take over · Stop" on the toolbar while an agent uses the tab ("pi is
// clicking 'Buy'" for an action); "You have control · pi waits · Hand back · Stop" after Take over.
// own_row: on a bar of its own under the toolbar (a narrow pane: browser_nav.odin), its text the
// room its buttons leave.
browser_agent_strip_layout :: proc(b: ^Browser, own_row: bool) {
	t := agent_tab_of(b.tab_id)
	th := theme()
	if own_row {
		room := pane_width() - px(2 * TERM_PAD + DOT + 3 * SP_2) - browser_agent_strip_buttons_w(b)
		what, on := strip_text(b, max(room, 0))
		if !on do return
		if clay.UI(cid("br_agent_bar"))({
			clip = {horizontal = true},
			layout = {sizing = {bar_w(), clay.SizingFixed(px(EDITOR_BAR_H))}, padding = {pu(TERM_PAD), pu(TERM_PAD), 0, 0}, childAlignment = {y = .Center}},
			backgroundColor = cc(th.bg_elevated),
			border = {color = cc(th.border), width = {bottom = pu(BORDER_W)}},
		}) {
			strip_parts(t, what)
		}
		return
	}
	what, on := strip_text(b)
	if !on do return
	strip_parts(t, what)
}

@(private = "file")
strip_parts :: proc(t: ^Agent_Tab, what: string) {
	th := theme()
	if clay.UI(cid("br_agent"))({layout = {sizing = {clay.SizingFit(), clay.SizingFixed(px(BUTTON_H))}, childGap = pu(SP_2), childAlignment = {y = .Center}}}) {
		dot(t.user_control ? th.waiting : th.accent)
		clay.TextDynamic(what, txt(th.text))
		if t.user_control do button(cid("br_agent_handback"), "Hand back", false, clay.PointerOver(cid("br_agent_handback")))
		else do button(cid("br_agent_takeover"), "Take over", false, clay.PointerOver(cid("br_agent_takeover")))
		button(cid("br_agent_stop"), "Stop", false, clay.PointerOver(cid("br_agent_stop")))
	}
}

// The width the strip takes on the toolbar now (0: none): the address field gives it way
// (browser_nav.odin), so the strip's buttons always show.
browser_agent_strip_w :: proc(b: ^Browser) -> f32 {
	what, on := strip_text(b)
	if !on do return 0
	return px(DOT) + text_w(what) + browser_agent_strip_buttons_w(b) + px(3 * SP_2)
}

// The strip's buttons (Take over or Hand back, Stop) with their gap: what it always shows (px).
browser_agent_strip_buttons_w :: proc(b: ^Browser) -> f32 {
	t := agent_tab_of(b.tab_id)
	if t == nil do return 0
	button_w :: proc(label: string) -> f32 {return text_w(label) + px(2 * SP_3)}
	return button_w(t.user_control ? "Hand back" : "Take over") + button_w("Stop") + px(SP_2)
}

// The strip's text, cut to a third of the bar.
@(private = "file")
strip_text :: proc(b: ^Browser, room := f32(-1)) -> (what: string, on: bool) {
	t := agent_tab_of(b.tab_id)
	if t == nil || !agent_strip_on(t) do return "", false
	who := agent_who(t.who, t.who_claude)
	doing := t.last != {} || agent_busy(b.tab_id)
	rec := recording(t)
	if rec != "" do rec = rec == "console,network" ? "recording console, network" : fmt.tprintf("recording %s", rec)
	// an action names its target ("pi is clicking 'Buy'"); the page wrote that name: one line
	target := t.doing >= .Clicking && t.act_target != "" ? fmt.tprintf("“%s”", one_line(cut_utf8(t.act_target, 60), context.temp_allocator)) : "this page"
	switch {
	case t.user_control:     what = fmt.tprintf("You have control · %s waits", who)
	case doing && rec != "": what = fmt.tprintf("%s is %s · %s", who, AGENT_DOING_NAMES[t.doing], rec)
	case doing:              what = fmt.tprintf("%s is %s %s", who, AGENT_DOING_NAMES[t.doing], target)
	case:                    what = fmt.tprintf("%s is %s", who, rec)
	}
	// at most a third of the bar (cut with …); on its own row the room its buttons leave
	if room >= 0 do return room < text_w("…") * 2 ? "" : clip(what, room), true
	room := px(200)
	if d := clay.GetElementData(cid("browser_bar")); d.found do room = max(min(d.boundingBox.width, pane_width()) / 3 - px(DOT + 2 * SP_2), px(80)) // at most its pane's: never wider for being wide
	return clip(what, room), true
}

// ---- test mode (autotest.odin) ----
//
//   agent_assert sent METHOD N     CDP calls of METHOD browser_agent sent to the tab on screen
//   agent_assert strip TEXT|-      the strip's text contains TEXT (- = no strip)
//   agent_assert wake yes|no       the tab on screen is woken for a screenshot
//   agent_assert stops N           Stop presses on the tab on screen
//   agent_assert has|not result|finished PATH TEXT   the last command's result (or long command's
//                                  finished result) has TEXT in its value at PATH (not: does not)
//   … tab=ID                       (sent, strip, wake, stops) that tab instead

agent_script :: proc(cmd: string, args: []string, rest: string) -> (msg: string, ok: bool) {
	if cmd != "agent_assert" || len(args) < 1 do return "agent_assert sent|strip|wake|stops …", false
	b := tab_browser()
	id: u64 = b != nil ? b.tab_id : 0
	if len(args) >= 2 && strings.has_prefix(args[len(args) - 1], "tab=") {
		v, _ := strconv.parse_u64(args[len(args) - 1][4:])
		id = v
	}
	t := agent_tab_of(id)
	got, want: string
	switch args[0] {
	case "sent":
		if len(args) < 3 do return "agent_assert sent METHOD N", false
		got = fmt.tprintf("%s %d", args[1], t != nil ? t.sent[args[1]] : 0)
		want = fmt.tprintf("%s %s", args[1], args[2])
	case "strip":
		want = strings.trim_space(rest[len(args[0]):])
		if i := strings.index(want, " tab="); i >= 0 do want = want[:i]
		got = "-"
		if t != nil && agent_strip_on(t) {
			got = fmt.tprintf("%s %s %s", agent_who(t.who, t.who_claude), AGENT_DOING_NAMES[t.doing], recording(t))
			if strings.contains(got, want) do got = want
		}
	case "wake":
		got = t != nil && t.wake ? "yes" : "no"
		want = len(args) > 1 ? args[1] : ""
	case "has", "not":
		if len(args) < 4 do return "agent_assert has|not result|finished PATH TEXT", false
		src := args[1] == "finished" ? autotest.last_finished : autotest.last_result
		// the text after PATH, as written
		text := rest
		for k in 0 ..< 3 {
			text = strings.trim_left_space(text)
			text = text[len(args[k]):]
		}
		text = strings.trim_space(text)
		v := json_path(src, args[2])
		if v == "<object>" do v = src // a list or an object: the whole answer (its JSON)
		if strings.contains(v, text) != (args[0] == "has") do return fmt.tprintf("ASSERT FAILED agent_assert %s %s %s %q: the value is %q", args[0], args[1], args[2], text, cut_utf8(v, 3000)), false
		fmt.printfln("[agent] assert ok: %s %s %s %q", args[0], args[1], args[2], text)
		return "", true
	case "stops":
		got = fmt.tprint(t != nil ? t.stops : 0)
		want = len(args) > 1 ? args[1] : ""
	case:
		return fmt.tprintf("agent_assert: unknown %s", args[0]), false
	}
	if got != want do return fmt.tprintf("ASSERT FAILED agent_assert %s: got %q, want %q", args[0], got, want), false
	fmt.printfln("[agent] assert ok: %s = %s", args[0], got)
	return "", true
}

// The command plumbing (type names, copies, events' fields): browser_wire.odin.
