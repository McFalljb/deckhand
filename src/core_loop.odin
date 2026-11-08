package main

// The core's tick: what runs whether or not a frame is drawn (design §10.2, M2-A). frame()
// calls it first; M2-C also calls it from a timer while no frames run.

import "base:runtime"

// The context Odin code runs in from C callbacks (ghostty's, the platform's, CEF's); main sets it
// at start.
app_context: runtime.Context

// The run's end and its frames (main.odin's App keeps the window's own state):
app_quitting: bool // quit confirmed (or nothing to confirm): the window may close, timers stop
app_stop_sessions: bool // that quit stops the session holder's sessions too (Quit.stop_sessions)
app_frames_called: u64 // frame callbacks, drawn or not (frame-pause measurements; per-frame caches)

core_tick :: proc() {
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
}
