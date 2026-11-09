package core

// The core loop's guard and its timer's 50 ms rule (core_loop.odin; design §10.2, M2-C), on a
// fake clock: no sleeps, no platform timer.

import "core:testing"
import "core:time"

// What a tick did, seen through the test step hook (the tick's second line).
@(private = "file")
Tick_Probe :: struct {
	runs:     int, // tick bodies run
	nested:   int, // core_tick calls made from inside a tick body
	overlaps: int, // a body that started while another ran (must stay 0)
	inside:   bool,
	reenter:  proc(), // called once from the first body (a modal loop's timer, a nested frame)
	fired:    bool, // what core_timer_fire said from inside
}
@(private = "file")
probe: Tick_Probe

@(private = "file")
probe_step :: proc() {
	if probe.inside do probe.overlaps += 1
	probe.inside = true
	defer probe.inside = false
	probe.runs += 1
	if probe.reenter != nil {
		r := probe.reenter
		probe.reenter = nil
		probe.nested += 1
		r()
	}
}

@(private = "file")
loop_setup :: proc() -> (saved_loop: Core_Loop, saved_step: proc(), saved_quit: bool) {
	saved_loop, saved_step, saved_quit = core_loop, window.test_step, app_quitting
	core_loop = {}
	probe = {}
	app_quitting = false
	window.test_step = probe_step
	return
}

@(private = "file")
loop_restore :: proc(saved_loop: Core_Loop, saved_step: proc(), saved_quit: bool) {
	core_loop, window.test_step, app_quitting = saved_loop, saved_step, saved_quit
	probe = {}
}

@(private = "file")
at :: proc(ms: int) -> time.Tick {return time.tick_add(time.Tick{_nsec = 1_000_000_000_000}, time.Duration(ms) * time.Millisecond)}

// A core_tick from inside a tick (a modal loop a command started runs the main queue) is skipped,
// then run right after the outer tick: never two at once.
@(test)
core_loop_nested_tick_runs_after :: proc(t: ^testing.T) {
	l, s, q := loop_setup()
	defer loop_restore(l, s, q)
	probe.reenter = proc() {core_tick()}
	core_tick()
	testing.expect_value(t, probe.nested, 1)
	testing.expect_value(t, probe.overlaps, 0) // skipped while the outer one ran
	testing.expect_value(t, probe.runs, 2) // and run after it
	testing.expect(t, !core_loop.ticking && !core_loop.missed)
	// the timer from inside a tick: the same
	probe = {reenter = proc() {probe.fired = core_timer_fire(at(1000))}}
	core_tick()
	testing.expect(t, !probe.fired, "the timer ticked inside a tick")
	testing.expect_value(t, probe.overlaps, 0)
	testing.expect_value(t, probe.runs, 2)
	testing.expect_value(t, core_loop.timer_ticks, 0)
}

// The timer inside a frame (or a modal loop frame() started, which may call frame() again) never
// ticks; the tick it skipped runs once the outermost frame ends.
@(test)
core_loop_timer_skips_frames :: proc(t: ^testing.T) {
	l, s, q := loop_setup()
	defer loop_restore(l, s, q)
	core_frame_begin(at(0))
	testing.expect(t, !core_timer_fire(at(500)), "ticked inside a frame") // a long modal loop
	testing.expect_value(t, probe.runs, 0)
	core_frame_begin(at(600)) // a frame from inside that modal loop
	testing.expect(t, !core_timer_fire(at(700)))
	core_frame_end(at(700))
	testing.expect_value(t, probe.runs, 0) // still inside the outer frame
	core_frame_end(at(710))
	testing.expect_value(t, probe.runs, 1) // the skipped tick, once, after the frame
	testing.expect_value(t, core_loop.skipped, 2)
	testing.expect(t, !core_loop.missed)
	// a frame with no timer call in it runs nothing extra at its end
	core_frame_begin(at(800))
	core_frame_end(at(800))
	testing.expect_value(t, probe.runs, 1)
	// a tick from inside a frame (frame() calls core_tick) runs at once
	core_frame_begin(at(900))
	core_tick()
	core_frame_end(at(900))
	testing.expect_value(t, probe.runs, 2)
}

// The 50 ms rule: the timer ticks only once no frame has started for CORE_IDLE_AFTER, and on every
// fire after that while frames stay away.
@(test)
core_loop_idle_rule :: proc(t: ^testing.T) {
	l, s, q := loop_setup()
	defer loop_restore(l, s, q)
	testing.expect(t, core_timer_fire(at(0)), "no frame yet: ticks") // before the first frame
	core_frame_begin(at(10))
	core_frame_end(at(10))
	testing.expect(t, !core_timer_fire(at(30)))
	testing.expect(t, !core_timer_fire(at(59))) // 49 ms
	testing.expect(t, core_timer_fire(at(60))) // 50 ms
	testing.expect(t, core_timer_fire(at(110)))
	testing.expect(t, core_timer_fire(at(160)))
	testing.expect_value(t, core_loop.timer_ticks, 4)
	testing.expect_value(t, probe.runs, 4)
	// frames are back (60 Hz): the timer stays out
	for i in 0 ..< 10 {
		core_frame_begin(at(200 + 16 * i))
		core_frame_end(at(200 + 16 * i + 2))
		testing.expect(t, !core_timer_fire(at(200 + 16 * i + 8)))
	}
	testing.expect_value(t, probe.runs, 4)
	// quitting, or stopped: never
	testing.expect(t, core_timer_due(at(10_000)))
	app_quitting = true
	testing.expect(t, !core_timer_fire(at(10_000)))
	app_quitting = false
	core_loop_stop()
	testing.expect(t, !core_timer_due(at(10_000)))
	testing.expect(t, !core_timer_fire(at(10_000)))
	core_frame_begin(at(10_001))
	core_loop.missed = true
	core_frame_end(at(10_001))
	testing.expect_value(t, probe.runs, 4) // nor after a frame
}

// Q11: App Nap is held off while some terminal had output in the last 2 s, or a job runs; the
// platform hears only when the answer changes.
@(test)
core_loop_output_activity :: proc(t: ^testing.T) {
	@(static) calls: [dynamic]bool
	clear(&calls)
	saved_platform, saved_reasons := platform, activity_reasons
	defer {platform, activity_reasons = saved_platform, saved_reasons}
	platform = {activity = proc(on: bool) {append(&calls, on)}}
	activity_reasons = {}
	saved_terms := terms
	terms = make(map[u64]^Term)
	defer {delete(terms); terms = saved_terms}
	x := new(Term)
	defer free(x)
	terms[1] = x
	output_activity_tick(at(0)) // no output yet
	testing.expect_value(t, len(calls), 0)
	x.last_output = at(100)
	output_activity_tick(at(150))
	output_activity_tick(at(1500))
	testing.expect_value(t, len(calls), 1)
	testing.expect(t, calls[0])
	activity_hold(.Jobs, true) // a job starts meanwhile: still on, nothing said
	output_activity_tick(at(2100)) // 2 s since the output
	testing.expect_value(t, len(calls), 1)
	activity_hold(.Jobs, false)
	testing.expect_value(t, len(calls), 2)
	testing.expect(t, !calls[1])
	output_activity_tick(at(3000))
	testing.expect_value(t, len(calls), 2)
	delete(calls)
	calls = nil
}

// The core's own timed upkeep runs from core_tick, so the timer runs it while no frames do: Copy
// a control token's clipboard clear (and the holder's retry, upgrade and restart outcome beside it).
@(test)
core_loop_tick_clears_token_clipboard :: proc(t: ^testing.T) {
	@(static) cleared: int
	cleared = -1
	l, s, q := loop_setup()
	defer loop_restore(l, s, q)
	saved_platform, saved_clip := platform, control_token_clip
	defer {platform, control_token_clip = saved_platform, saved_clip}
	platform = {clear_clipboard_if = proc(count: int) {cleared = count}}
	control_token_clip.count = 7
	control_token_clip.deadline = time.tick_add(time.tick_now(), -time.Second) // its minute is up
	testing.expect(t, core_timer_fire(at(0)), "the timer did not tick")
	testing.expect_value(t, cleared, 7)
	testing.expect(t, control_token_clip.deadline == {})
}

// The 50 ms count from a frame's end, not its start: a 70 ms frame, then the timer 5 ms later,
// must not tick (a frame just ran the core).
@(test)
core_loop_idle_from_frame_end :: proc(t: ^testing.T) {
	l, s, q := loop_setup()
	defer loop_restore(l, s, q)
	core_frame_begin(at(0))
	core_frame_end(at(70))
	testing.expect(t, !core_timer_fire(at(75)), "ticked 5 ms after a frame ended")
	testing.expect(t, !core_timer_fire(at(119)))
	testing.expect(t, core_timer_fire(at(120)))
	testing.expect_value(t, probe.runs, 1)
}

// A quit that frames would carry out (sokol closes the window from a frame) while no frame runs
// (minimised, App Nap): after QUIT_STALL_AFTER the timer says to close the window itself.
@(test)
core_loop_quit_stalled :: proc(t: ^testing.T) {
	l, s, q := loop_setup()
	defer loop_restore(l, s, q)
	core_frame_begin(at(0))
	core_frame_end(at(10))
	testing.expect(t, !core_quit_stalled(at(1000)), "not quitting")
	app_quitting = true
	testing.expect(t, !core_quit_stalled(at(150)), "frames may still come")
	testing.expect(t, core_quit_stalled(at(210)))
	core_frame_begin(at(300)) // inside a frame (a modal loop): never
	testing.expect(t, !core_quit_stalled(at(600)))
	core_frame_end(at(600))
	core_loop_stop() // the quit went through (QUIT_REQUESTED, cleanup)
	testing.expect(t, !core_quit_stalled(at(2000)))
}

// After CORE_IDLE_SLOW_AFTER of timer ticks with nothing going on, the timer slows to
// CORE_TIMER_SLOW; a frame, a wake or something going on brings it back to CORE_TIMER_EVERY.
@(test)
core_loop_timer_backs_off :: proc(t: ^testing.T) {
	@(static) periods: [dynamic]time.Duration
	clear(&periods)
	l, s, q := loop_setup()
	defer loop_restore(l, s, q)
	saved_platform, saved_reasons, saved_clip := platform, activity_reasons, control_token_clip
	defer {platform, activity_reasons, control_token_clip = saved_platform, saved_reasons, saved_clip}
	activity_reasons, control_token_clip = {}, {}
	platform = {core_timer = proc(every: time.Duration, fire: proc()) {append(&periods, every)}}
	core_loop_start()
	testing.expect_value(t, len(periods), 1)
	testing.expect_value(t, periods[0], CORE_TIMER_EVERY)
	ms := 0
	for ; ms < 2900; ms += 50 do core_timer_fire(at(ms))
	testing.expect_value(t, len(periods), 1) // under 3 s idle: still 50 ms
	for ; ms < 3200; ms += 50 do core_timer_fire(at(ms))
	testing.expect_value(t, len(periods), 2)
	testing.expect_value(t, periods[1], CORE_TIMER_SLOW)
	core_timer_fire(at(ms + 500)) // slow and idle: nothing changes
	testing.expect_value(t, len(periods), 2)
	core_loop_wake() // a command from another thread
	testing.expect_value(t, len(periods), 3)
	testing.expect_value(t, periods[2], CORE_TIMER_EVERY)
	for ms = 10_000; ms < 13_500; ms += 50 do core_timer_fire(at(ms)) // slow again
	testing.expect_value(t, periods[len(periods) - 1], CORE_TIMER_SLOW)
	core_frame_begin(at(20_000)) // frames are back
	core_frame_end(at(20_010))
	testing.expect_value(t, periods[len(periods) - 1], CORE_TIMER_EVERY)
	for ms = 30_000; ms < 33_500; ms += 50 do core_timer_fire(at(ms))
	testing.expect_value(t, periods[len(periods) - 1], CORE_TIMER_SLOW)
	control_token_clip.deadline = time.tick_add(time.tick_now(), time.Hour) // a clear to come: busy
	core_timer_fire(at(34_000))
	testing.expect_value(t, periods[len(periods) - 1], CORE_TIMER_EVERY)
	control_token_clip = {}
	delete(periods)
	periods = nil
}
