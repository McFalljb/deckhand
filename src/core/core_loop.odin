package core

// The core's tick: what runs whether or not a frame is drawn (design §10.2, M2-A, M2-C). frame()
// calls it first; while no frame has run for CORE_IDLE_AFTER (the window hidden or minimised, App
// Nap), a main-queue timer calls it instead (core_timer_fire), so parsing, status dots, exits,
// bells and saving go on. Never inside frame() or a modal loop frame() started: a call then is
// skipped and run once that ends (core_tick_guarded, core_frame_end).

import "base:runtime"
import "core:time"

// The context Odin code runs in from C callbacks (ghostty's, the platform's, CEF's); main sets it
// at start.
app_context: runtime.Context

// The run's end and its frames (main.odin's App keeps the window's own state):
app_quitting: bool // quit confirmed (or nothing to confirm): the window may close, timers stop
app_stop_sessions: bool // that quit stops the session holder's sessions too (Quit.stop_sessions)
app_frames_called: u64 // frame callbacks, drawn or not (frame-pause measurements; per-frame caches)

CORE_IDLE_AFTER :: 50 * time.Millisecond // no frame for this long: the timer ticks the core
CORE_TIMER_EVERY :: 50 * time.Millisecond // the timer's period (platform.core_timer)
OUTPUT_ACTIVE_FOR :: 2 * time.Second // a terminal's output this recent holds off App Nap (Q11)

// The core loop's own state (main thread only).
Core_Loop :: struct {
	ticking:     bool, // core_tick runs now
	frame_depth: int, // frame() runs now (a modal loop it started may call frame() again)
	missed:      bool, // a call came while ticking or in a frame: run once that ends
	last_frame:  time.Tick, // the last frame's start; {} = none yet
	stopped:     bool, // the timer does nothing more (quitting)
	timer_ticks: u64, // ticks the timer ran (test mode logs it: hidden-window.sh)
	skipped:     u64, // timer fires skipped because a tick or a frame ran
}
core_loop: Core_Loop

// The tick itself, once: from core_tick_guarded only.
@(private = "file")
core_tick_body :: proc() {
	inbox_drain()
	if window.test_step != nil do window.test_step() // test mode's script (autotest.odin)
	pump_all()
	pty_reap()
	persist_tick()
	titles_tick() // titles the worker read (titles.odin)
	jobs_tick() // Atlas's jobs: notes, the clock, running runs (jobs.odin)
	agent_pending_tick() // Send to Atlas text that waited too long for pi (session_info.odin)
	claude_tick() // Claude tabs: held texts that can go now, their Enter (claude.odin)
	claude_wait_tick() // claude_wait_idle: waits whose Claude tab is idle, gone or past its deadline (claude_wait.odin)
	dead_tab_tick() // Restart with model…: pi's selector once the new pi is up (dead_tab.odin)
	control_token_clip_tick() // Copy a control token: off the clipboard after a minute (commands.odin)
	holder_successor_retry_tick() // after REFUSED{secret}: attach again once the reservation lapsed (holder_client.odin)
	holder_upgrade_tick() // an older holder than the bundled one: upgraded once, after the adopt (holder_restart.odin)
	holder_restart_tick() // Restart session holder's outcome, as a toast (holder_restart.odin; the toast redraws)
	output_activity_tick(time.tick_now())
}

// One core tick (frame() calls it first). A call from inside a tick (a modal loop a command
// started runs the main queue: the timer, a frame) is skipped and run right after the outer one.
core_tick :: proc() {
	if core_loop.ticking {
		core_loop.missed = true
		return
	}
	core_loop.ticking = true
	defer core_loop.ticking = false
	core_loop.missed = false
	core_tick_body()
	// a nested call came meanwhile: once more, then stop (it may come again in a long modal)
	for i := 0; core_loop.missed && i < 2; i += 1 {
		core_loop.missed = false
		core_tick_body()
	}
}

// frame() starts and ends (main.odin): frames run the core themselves, so the timer stays out
// meanwhile; one it skipped runs as the outermost frame ends.
core_frame_begin :: proc(now: time.Tick) {
	core_loop.frame_depth += 1
	core_loop.last_frame = now
}
core_frame_end :: proc() {
	core_loop.frame_depth -= 1
	if core_loop.frame_depth > 0 do return
	core_loop.frame_depth = 0
	if core_loop.missed && !core_loop.ticking && !core_loop.stopped {
		core_loop.missed = false
		core_tick()
	}
}

// Whether the timer should tick the core at now: no frame for CORE_IDLE_AFTER, none running and no
// tick running. Pure but for the state it reads.
core_timer_due :: proc(now: time.Tick) -> bool {
	if core_loop.stopped || core_loop.frame_depth > 0 || core_loop.ticking do return false
	return core_loop.last_frame == {} || time.tick_diff(core_loop.last_frame, now) >= CORE_IDLE_AFTER
}

// The timer (platform.core_timer, every CORE_TIMER_EVERY on the main queue): a tick while frames
// don't run. Inside a frame or a tick it is skipped and remembered (run when that ends). True: it
// ticked.
core_timer_fire :: proc(now: time.Tick) -> bool {
	if core_loop.stopped || app_quitting do return false
	if core_loop.frame_depth > 0 || core_loop.ticking {
		core_loop.missed = true
		core_loop.skipped += 1
		return false
	}
	if !core_timer_due(now) do return false
	core_loop.timer_ticks += 1
	core_tick()
	return true
}

// Main thread, once init is done: the platform's timer starts (nil in unit tests: nothing).
core_loop_start :: proc() {
	core_loop.stopped = false
	if platform.core_timer != nil do platform.core_timer(CORE_TIMER_EVERY, proc() {core_timer_fire(time.tick_now())})
}

// Quitting: the timer does nothing more.
core_loop_stop :: proc() {core_loop.stopped = true}

// Q11: while some terminal had output in the last OUTPUT_ACTIVE_FOR, App Nap stays off (parsing
// keeps up with a hidden window's output; it costs energy, so only then).
output_activity_tick :: proc(now: time.Tick) {
	recent := false
	for _, t in terms {
		if t.last_output != {} && time.tick_diff(t.last_output, now) < OUTPUT_ACTIVE_FOR {
			recent = true
			break
		}
	}
	activity_hold(.Output, recent)
}
