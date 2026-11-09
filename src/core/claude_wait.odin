package core

// claude_wait_idle (docs/PROTOCOL.md §3, Claude Code tabs): Atlas, scripts and the user wait until
// a Claude tab is idle, as pi_wait_idle does for a pi tab through its bridge. Deckhand answers it
// itself: a Claude tab has no bridge, its turn comes from the plugin's hooks (claude.turn) and
// Claude's own OSC 7501 status (agent_status.odin).
//
// Idle: Claude runs in the tab, its hooks say idle, its OSC 7501 status (when it reports one) is
// neither working nor blocked, no claude_prompt text is held for it, and the user has typed
// nothing into it since their last message; all of that for CLAUDE_WAIT_SETTLE (a Stop hook and
// the next turn's start can be a frame apart). A permission dialog keeps it waiting, as a pi
// dialog keeps pi_wait_idle waiting. Long-running: `pending`, then a `finished` event, ok, or an
// error with data.code timeout (and why it is still busy), tab_gone (Claude exited or its tab
// closed) or cancelled (the requester's cancel line, or its connection closed).
//
// Tab callers (pi tabs' bridges, Claude tabs' CLI) may not send it (who .Anyone); a caller bound
// to a tab never waits on its own. At most CLAUDE_WAITS_PER_CONN per requester connection (one
// that never cancels blocks only itself), CLAUDE_WAITS_MAX in all. prompt_id (claude_prompt's
// data.id): if the user drops that held text, the wait ends with code dropped. A wait is on one
// run of Claude: a restart in the tab (claude_start) ends it with tab_gone.
//
// Frames pause (the window minimised or hidden, App Nap), so while a wait or a held text exists a
// timer thread submits Claude_Wait_Tick every CLAUDE_TIMER_EVERY: it runs claude_tick (held texts,
// their Enter) and claude_wait_tick, as jobs_timer does for the scheduler.

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

Claude_Wait_Idle :: struct {
	tab_id:     u64,
	timeout_ms: u64, // 0: no timeout
	prompt_id:  u64, // a held text's id (claude_prompt): its drop ends the wait
}
// The timer's tick (internal): held texts and waits while frames are paused.
Claude_Wait_Tick :: struct {}

CLAUDE_WAIT_SETTLE :: 300 * time.Millisecond
CLAUDE_WAITS_MAX :: 64
CLAUDE_WAITS_PER_CONN :: 8
CLAUDE_WAIT_MAX_MS :: 24 * 3600 * 1000 // a longer timeout_ms is clamped (no overflow)
CLAUDE_TIMER_EVERY :: 100 * time.Millisecond
CLAUDE_DROPPED_KEEP :: 64

@(private = "file")
Claude_Waiter :: struct {
	request_id: u64,
	tab_id:     u64,
	conn:       u64, // the requester's connection (0: none: the user, a script, Deckhand)
	start:      u64, // the tab's claude_start count when the wait began
	prompt_id:  u64,
	deadline:   time.Tick, // zero: none
	timeout_ms: u64,
	idle_since: time.Tick, // zero: not idle at the last tick
}

@(private = "file")
claude_waits: [dynamic]Claude_Waiter
@(private = "file")
claude_starts: map[u64]u64 // tab -> how many times Claude started in it
@(private = "file")
claude_dropped: [dynamic]u64 // ids of held texts the user dropped, the latest CLAUDE_DROPPED_KEEP
@(private = "file")
claude_held_seq: u64

// The requester's connection for a request id (tests replace it); nil: socket_request_conn.
claude_wait_conn_of: proc(request_id: u64) -> u64

claude_wait_test_finished: ^map[u64]string // tests: every finished result by request id

// Why a Claude tab is not idle for claude_wait_idle ("" = it is).
claude_wait_why :: proc(tab: ^Tab) -> string {
	ct, is := &tab.kind.(Claude_Tab)
	if !is do return "not a Claude tab"
	if tab.status != .Running do return "Claude is not running in this tab"
	switch ct.turn {
	case .Unknown: return "Claude is starting"
	case .Working: return "Claude is working"
	case .Waiting: return "Claude is waiting for the user"
	case .Idle:
	}
	if v := tab_status_view(tab^); v.source == .Osc7501 {
		#partial switch v.state {
		case .Blocked: return "Claude is waiting for the user"
		case .Working: return "Claude is working"
		}
	}
	if n := len(ct.held); n > 0 do return n == 1 ? "1 held text waits to go" : fmt.tprintf("%d held texts wait to go", n)
	if claude_typed(tab.id) do return "the user is typing in it"
	return ""
}

claude_wait_apply :: proc(c: Claude_Wait_Idle, caller: Caller, request_id: u64) -> (Result, bool) {
	_, tab, ct := claude_tab_of(c.tab_id)
	if ct == nil do return fail("no such Claude tab"), false
	if owns_tab(caller, c.tab_id) do return fail("a caller cannot act on its own tab"), false
	if tab.status != .Running do return fail("Claude is not running in this tab"), false
	conn := claude_wait_conn_of != nil ? claude_wait_conn_of(request_id) : socket_request_conn(request_id)
	mine := 0
	for w in claude_waits do if w.conn == conn do mine += 1
	if mine >= CLAUDE_WAITS_PER_CONN do return fail(fmt.tprintf("%d waits on Claude tabs from this connection are running already: cancel one", CLAUDE_WAITS_PER_CONN)), false
	if len(claude_waits) >= CLAUDE_WAITS_MAX do return fail(fmt.tprintf("%d waits on Claude tabs are running already", CLAUDE_WAITS_MAX)), false
	ms := min(c.timeout_ms, CLAUDE_WAIT_MAX_MS)
	w := Claude_Waiter{request_id = request_id, tab_id = c.tab_id, conn = conn, start = claude_starts[c.tab_id], prompt_id = c.prompt_id, timeout_ms = ms}
	if ms > 0 do w.deadline = time.tick_add(time.tick_now(), time.Duration(ms) * time.Millisecond)
	append(&claude_waits, w)
	claude_timer_kick()
	return {ok = true, pending = true}, false
}

// Claude started in the tab (claude_start): waits on its earlier run end (tab_gone).
claude_wait_started :: proc(tab_id: u64) {claude_starts[tab_id] += 1}

// Which run of Claude a tab is on (claude_status.odin keys its records by it).
claude_wait_run :: proc(tab_id: u64) -> u64 {return claude_starts[tab_id]}

// A new held text's id (claude_prompt's data.id), never 0.
claude_held_id :: proc() -> u64 {
	claude_held_seq += 1
	return claude_held_seq
}

// The user dropped held text `id` (the held bar's Drop): a wait naming it ends (code dropped).
claude_wait_dropped :: proc(id: u64) {
	if id == 0 do return
	if len(claude_dropped) >= CLAUDE_DROPPED_KEEP do ordered_remove(&claude_dropped, 0)
	append(&claude_dropped, id)
}

// Frame upkeep (main.odin) and the timer's Claude_Wait_Tick: the waits whose tab is idle, gone,
// restarted or past its deadline, or whose prompt was dropped, end.
claude_wait_tick :: proc(at: time.Tick = {}) {
	now := at == {} ? time.tick_now() : at
	claude_status_tick(now) // when Claude's prompt came up: the "hooks not running" bar (claude_status.odin)
	claude_panels_tick(now) // running subagents' times (claude_panels.odin)
	for i := 0; i < len(claude_waits); {
		w := &claude_waits[i]
		_, tab, ct := claude_tab_of(w.tab_id)
		r: Result
		done := false
		dropped := false
		if w.prompt_id != 0 do for d in claude_dropped do if d == w.prompt_id do dropped = true
		if ct == nil || tab.status != .Running || claude_starts[w.tab_id] != w.start {
			r, done = code_fail("tab_gone", "Claude exited or its tab closed"), true
		} else if dropped {
			r, done = code_fail("dropped", "the user dropped the held text in Deckhand before it was sent"), true
		} else if why := claude_wait_why(tab); why == "" {
			if w.idle_since == {} do w.idle_since = now
			// idle; what still runs in the background (its last Stop) goes with the result, as data
			if time.tick_diff(w.idle_since, now) >= CLAUDE_WAIT_SETTLE do r, done = {ok = true, data = claude_background_result(w.tab_id)}, true
		} else {
			w.idle_since = {}
			if w.deadline != {} && time.tick_diff(w.deadline, now) >= 0 {
				r, done = code_fail("timeout", fmt.tprintf("still not idle after %v s: %s", f64(w.timeout_ms) / 1000, why)), true
			}
		}
		if !done {
			i += 1
			continue
		}
		id := w.request_id
		ordered_remove(&claude_waits, i)
		claude_wait_finish(id, r)
	}
	sync.atomic_store(&claude_timer_want, claude_wait_timer_wanted())
}

// The requester cancelled request_id or its connection closed (Request_Cancel): true if it was a wait here.
claude_wait_cancel :: proc(request_id: u64, why: string) -> bool {
	for w, i in claude_waits do if w.request_id == request_id {
		ordered_remove(&claude_waits, i)
		claude_wait_finish(request_id, code_fail("cancelled", why))
		return true
	}
	return false
}

claude_wait_count :: proc() -> int {return len(claude_waits)}

// Tests: no waits left from an earlier test.
claude_wait_reset :: proc() {clear(&claude_waits)}

// ---- the timer (frames may be paused) ----

// Whether the timer should run: a wait, or a held text in some Claude tab.
claude_wait_timer_wanted :: proc() -> bool {
	if len(claude_waits) > 0 do return true
	for s in state.open_sessions do for tab in s.tabs do if ct, is := tab.kind.(Claude_Tab); is && len(ct.held) > 0 do return true
	return false
}

@(private = "file")
claude_timer_want: bool // set on the main thread, read by the timer
@(private = "file")
claude_timer_alive: bool

// Main thread: say whether the timer is wanted now; start it if it is and none runs.
claude_timer_kick :: proc() {
	want := claude_wait_timer_wanted()
	sync.atomic_store(&claude_timer_want, want)
	if !want || ODIN_TEST do return
	if _, ok := sync.atomic_compare_exchange_strong(&claude_timer_alive, false, true); ok do thread.run(claude_timer)
}

@(private = "file")
claude_timer :: proc() {
	for {
		time.sleep(CLAUDE_TIMER_EVERY)
		if sync.atomic_load(&claude_timer_want) {
			inbox_submit(Claude_Wait_Tick{}, {kind = .Internal})
			continue
		}
		// nothing to do: stop, unless the main thread wanted it again meanwhile (it saw us alive)
		sync.atomic_store(&claude_timer_alive, false)
		if !sync.atomic_load(&claude_timer_want) do return
		if _, ok := sync.atomic_compare_exchange_strong(&claude_timer_alive, false, true); !ok do return
	}
}

// Claude_Wait_Tick: what a frame would do for Claude tabs.
claude_wait_tick_apply :: proc() -> (Result, bool) {
	claude_tick()
	claude_wait_tick()
	claude_timer_kick()
	return {ok = true}, false
}

@(private = "file")
code_fail :: proc(code, msg: string) -> Result {
	return {error = msg, data = fmt.tprintf(`{{"code":"%s"}}`, code)}
}

@(private = "file")
claude_wait_finish :: proc(request_id: u64, r: Result) {
	if claude_wait_test_finished != nil do claude_wait_test_finished[request_id] = strings.clone(result_json(r))
	emit_event(Finished_Event{request_id = request_id, result = r})
}

claude_wait_write :: proc(b: ^strings.Builder, c: Claude_Wait_Idle) {
	fmt.sbprintf(b, `,"tab_id":%d`, c.tab_id)
	if c.timeout_ms != 0 do fmt.sbprintf(b, `,"timeout_ms":%d`, c.timeout_ms)
	if c.prompt_id != 0 do fmt.sbprintf(b, `,"prompt_id":%d`, c.prompt_id)
}
