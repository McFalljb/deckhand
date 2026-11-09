#+build darwin
package holder

// The supervisor (supervisor.odin) on a fake clock, and SUPERVISE over a socketpair.

import "core:testing"
import "core:time"
import "../holderwire"
import "../trust"

@(private = "file")
at :: proc(s: f64) -> time.Tick {return time.Tick{_nsec = 1_000_000_000_000 + i64(s * 1e9)}}

@(test)
supervisor_crashes_backoff_rollback_health :: proc(t: ^testing.T) {
	s: Supervisor
	defer {delete(s.path); delete(s.crashes)}
	// an in-process core (it never said SUPERVISE) is never relaunched
	sup_core_gone(&s, true, at(0))
	testing.expect_value(t, sup_tick(&s, at(100), false), Sup_Action.None)
	// a separate core crashes: relaunched after 1 s, the same binary
	sup_core_said(&s, "/x/deckhand-core-serve", at(0))
	sup_core_gone(&s, true, at(10))
	testing.expect_value(t, sup_tick(&s, at(10.5), false), Sup_Action.None)
	testing.expect_value(t, sup_tick(&s, at(11), false), Sup_Action.Launch)
	testing.expect_value(t, sup_launch_path(&s, "/d"), "/x/deckhand-core-serve")
	testing.expect(t, !s.rolled_back)
	// it comes back, and crashes again within 5 min: the previous core, after 2 s
	sup_core_said(&s, "/x/deckhand-core-serve", at(12))
	sup_core_gone(&s, true, at(20))
	testing.expect(t, s.rolled_back)
	testing.expect_value(t, sup_tick(&s, at(21), false), Sup_Action.None)
	testing.expect_value(t, sup_tick(&s, at(22), false), Sup_Action.Launch)
	testing.expect_value(t, sup_launch_path(&s, "/d"), "/d/" + SUP_PREVIOUS)
	// it never says SUPERVISE: a failure after SUP_LAUNCH_WAIT, launched again (4 s)
	testing.expect_value(t, sup_tick(&s, at(42), false), Sup_Action.None)
	testing.expect(t, s.next_launch != {})
	testing.expect_value(t, sup_tick(&s, at(46), false), Sup_Action.Launch)
	// a core is attached (the window launched one): no second launch
	s.next_launch = at(50)
	testing.expect_value(t, sup_tick(&s, at(60), true), Sup_Action.None)
	// healthy after 60 s attached: the counts start over
	sup_core_said(&s, "/p/deckhand-core-serve", at(70))
	_ = sup_tick(&s, at(131), true)
	testing.expect(t, s.healthy && s.failures == 0 && len(s.crashes) == 0)
	// a GOODBYE (a handover, an idle exit): nothing is relaunched
	sup_core_gone(&s, false, at(200))
	testing.expect_value(t, sup_tick(&s, at(400), false), Sup_Action.None)
	// failures in a row: the backoff grows to its cap, then it gives up
	s2: Supervisor
	defer {delete(s2.path); delete(s2.crashes)}
	sup_core_said(&s2, "/x/deckhand-core-serve", at(0))
	now := 0.0
	sup_core_gone(&s2, true, at(now))
	for !s2.gave_up {
		now += 100
		testing.expect_value(t, sup_tick(&s2, at(now), false), Sup_Action.Launch)
		now += 1
		_ = sup_tick(&s2, at(now + 20), false) // never came back
		now += 20
	}
	testing.expect_value(t, s2.failures, SUP_MAX_FAILURES)
	testing.expect_value(t, sup_backoff(10), SUP_BACKOFF_MAX)
	testing.expect_value(t, sup_tick(&s2, at(now + 1000), false), Sup_Action.None)
	// the window's Use previous core starts it again
	sup_use_previous(&s2, at(now + 1000))
	testing.expect(t, s2.rolled_back) // the window launches the previous core too
	testing.expect_value(t, sup_tick(&s2, at(now + 1000), false), Sup_Action.Launch)
	testing.expect_value(t, sup_launch_path(&s2, "/d"), "/d/" + SUP_PREVIOUS)
}

// SUPERVISE{status} as a first frame: only from a window's code; anything else is dropped unanswered.
@(test)
supervise_needs_a_window :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	f := fake_connect(t, h)
	defer fake_free(f)
	fake_send(f, .Supervise, 0, holderwire.Supervise{op = "status"})
	testing.expect(t, wait_eof(h, f))
	testing.expect_value(t, len(f.frames), 0)
	// the test binary's own identifier as the window's: answered, then closed
	own := []string{trust.own_signature().identifier}
	h.cfg.window_ids = own
	f2 := fake_connect(t, h)
	defer fake_free(f2)
	fake_send(f2, .Supervise, 0, holderwire.Supervise{op = "status"})
	g, ok := wait_for(h, f2, .Supervise_Status)
	st: holderwire.Supervise_Status
	testing.expect(t, ok && decode_got(g, .Supervise_Status, &st))
	testing.expect(t, !st.core && !st.rolled_back && st.crashes == 0)
	testing.expect(t, wait_eof(h, f2))
	// a core's SUPERVISE{core}: it is watched, and its crash plans a relaunch
	f3 := fake_connect(t, h)
	defer fake_free(f3)
	hello(t, h, f3)
	fake_send(f3, .Supervise, 0, holderwire.Supervise{op = "core", path = "/x/deckhand-core-serve"})
	_, ok = wait_for(h, f3, .Supervise_Status)
	testing.expect(t, ok, "no SUPERVISE_STATUS for the core")
	testing.expect_value(t, h.sup.path, "/x/deckhand-core-serve")
	close(f3.fd)
	f3.fd = -1
	for _ in 0 ..< 200 {
		if h.core == nil do break
		holder_step(h, 2)
	}
	testing.expect(t, h.sup.next_launch != {}, "no relaunch planned after the crash")
	h.sup.next_launch = {} // never launch /x
}

// A handover's successor that dies before it says SUPERVISE counts as a crash: relaunched, and a
// second failure rolls back to the previous core. A core that then stays up resets the rollback.
@(test)
supervisor_successor_dies :: proc(t: ^testing.T) {
	s: Supervisor
	defer {delete(s.path); delete(s.crashes)}
	sup_core_said(&s, "/x/deckhand-core-serve", at(0))
	sup_successor_named(&s, at(100)) // GOODBYE{handover, successor}
	testing.expect_value(t, sup_tick(&s, at(110), false), Sup_Action.None)
	testing.expect_value(t, sup_tick(&s, at(120), false), Sup_Action.None) // SUP_LAUNCH_WAIT ran out
	testing.expect_value(t, s.failures, 1)
	testing.expect_value(t, sup_tick(&s, at(121), false), Sup_Action.Launch)
	_ = sup_tick(&s, at(141), false) // that one never came back either
	testing.expect(t, s.rolled_back)
	testing.expect_value(t, sup_tick(&s, at(143), false), Sup_Action.Launch)
	testing.expect_value(t, sup_launch_path(&s, "/d"), "/d/" + SUP_PREVIOUS)
	sup_core_said(&s, "/d/" + SUP_PREVIOUS, at(144))
	_ = sup_tick(&s, at(205), true)
	testing.expect(t, s.healthy && !s.rolled_back && !s.use_previous)
	// a plain goodbye (no successor): nothing is waited for
	sup_core_gone(&s, false, at(300))
	testing.expect_value(t, sup_tick(&s, at(400), false), Sup_Action.None)
}
