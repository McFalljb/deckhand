#+build darwin
package holder

// The supervisor (supervisor.odin) on a fake clock, and SUPERVISE over a socketpair.

import "core:fmt"
import "core:sys/posix"
import "core:strings"
import "core:testing"
import "core:time"
import "../holderwire"
import "../trust"

@(private = "file")
at :: proc(s: f64) -> time.Tick {return time.Tick{_nsec = 1_000_000_000_000 + i64(s * 1e9)}}

@(test)
supervisor_crashes_backoff_health :: proc(t: ^testing.T) {
	s: Supervisor
	defer delete(s.path)
	// an in-process core (it never said SUPERVISE) is never relaunched
	sup_core_gone(&s, true, at(0))
	testing.expect_value(t, sup_tick(&s, at(100), false), Sup_Action.None)
	// a separate core crashes: relaunched after 1 s; nothing installed: the binary it named
	sup_core_said(&s, "/x/deckhand-core-serve", at(0))
	sup_core_gone(&s, true, at(10))
	testing.expect_value(t, sup_tick(&s, at(10.5), false), Sup_Action.None)
	testing.expect_value(t, sup_tick(&s, at(11), false), Sup_Action.Launch)
	testing.expect_value(t, sup_launch_path(&s, "/nonexistent"), "/x/deckhand-core-serve")
	// it comes back, and crashes again: the same core again (never a rollback), after 2 s
	sup_core_said(&s, "/x/deckhand-core-serve", at(12))
	sup_core_gone(&s, true, at(20))
	testing.expect_value(t, sup_tick(&s, at(21), false), Sup_Action.None)
	testing.expect_value(t, sup_tick(&s, at(22), false), Sup_Action.Launch)
	testing.expect_value(t, sup_launch_path(&s, "/nonexistent"), "/x/deckhand-core-serve")
	// it never says SUPERVISE: a failure after SUP_LAUNCH_WAIT, launched again (4 s)
	testing.expect_value(t, sup_tick(&s, at(42), false), Sup_Action.None)
	testing.expect(t, s.next_launch != {})
	testing.expect_value(t, sup_tick(&s, at(46), false), Sup_Action.Launch)
	// a core is attached (the window launched one): no second launch
	s.next_launch = at(50)
	testing.expect_value(t, sup_tick(&s, at(60), true), Sup_Action.None)
	// healthy after 60 s attached: the count starts over
	sup_core_said(&s, "/p/deckhand-core-serve", at(70))
	_ = sup_tick(&s, at(131), true)
	testing.expect(t, s.healthy && s.failures == 0)
	// a GOODBYE (a handover, an idle exit): nothing is relaunched
	sup_core_gone(&s, false, at(200))
	testing.expect_value(t, sup_tick(&s, at(400), false), Sup_Action.None)
	// failures in a row: the backoff grows to its cap, then it gives up
	s2: Supervisor
	defer delete(s2.path)
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
	testing.expect_value(t, sup_tick(&s2, at(now + 1000), false), Sup_Action.Launch)
}

// What is launched: current; previous only while the user's marker names the current key.
@(test)
supervisor_launch_path :: proc(t: ^testing.T) {
	tmp := context.temp_allocator
	cs :: proc(p: string) -> cstring {return strings.clone_to_cstring(p, context.temp_allocator)}
	put :: proc(path, text: string) {
		fd := posix.open(cs(path), {.WRONLY, .CREAT, .TRUNC}, {.IRUSR, .IWUSR})
		posix.write(fd, raw_data(text), len(text))
		posix.close(fd)
	}
	d := fmt.tprintf("%s/dksup-%d", strings.trim_right(string(posix.getenv("TMPDIR")), "/"), time.tick_now()._nsec % 1_000_000_000)
	defer {
		cmd := fmt.tprintf("rm -rf '%s'", d)
		posix.system(strings.clone_to_cstring(cmd, tmp))
	}
	for k in ([]string{"1-aaa", "2-bbb"}) {
		bin := fmt.tprintf("%s/core/%s/Deckhand Core.app/Contents/MacOS", d, k)
		posix.system(cs(fmt.tprintf("mkdir -p '%s'", bin)))
		put(fmt.tprintf("%s/%s", bin, SUP_SERVE_BIN), "x")
	}
	posix.symlink("2-bbb", cs(fmt.tprintf("%s/core/current", d)))
	posix.symlink("1-aaa", cs(fmt.tprintf("%s/core/previous", d)))
	s: Supervisor
	defer delete(s.path)
	sup_core_said(&s, "/x/deckhand-core-serve", at(0))
	testing.expect_value(t, sup_launch_path(&s, d), fmt.tprintf("%s/%s", d, SUP_CURRENT))
	put(fmt.tprintf("%s/%s", d, SUP_MARKER), "2-bbb")
	testing.expect_value(t, sup_launch_path(&s, d), fmt.tprintf("%s/%s", d, SUP_PREVIOUS))
	put(fmt.tprintf("%s/%s", d, SUP_MARKER), "0-old") // another build's
	testing.expect_value(t, sup_launch_path(&s, d), fmt.tprintf("%s/%s", d, SUP_CURRENT))
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
	testing.expect(t, !st.core && !st.gave_up && st.crashes == 0)
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

// A handover's successor that dies before it says SUPERVISE counts as a crash: the holder forgets
// its secret (so the core launched now is welcomed) and relaunches.
@(test)
supervisor_successor_dies :: proc(t: ^testing.T) {
	s: Supervisor
	defer delete(s.path)
	sup_core_said(&s, "/x/deckhand-core-serve", at(0))
	sup_successor_named(&s, at(100)) // GOODBYE{handover, successor}
	testing.expect_value(t, sup_tick(&s, at(110), false), Sup_Action.None)
	testing.expect(t, sup_wait_over(&s, at(120)))
	testing.expect_value(t, sup_tick(&s, at(120), false), Sup_Action.None) // SUP_LAUNCH_WAIT ran out
	testing.expect_value(t, s.failures, 1)
	testing.expect_value(t, sup_tick(&s, at(121), false), Sup_Action.Launch)
	// a plain goodbye (no successor): nothing is waited for
	sup_core_said(&s, "/x/deckhand-core-serve", at(130))
	sup_core_gone(&s, false, at(300))
	testing.expect_value(t, sup_tick(&s, at(400), false), Sup_Action.None)
}

// In the holder: the expiry clears the successor secret before the relaunch.
@(test)
supervisor_successor_secret_goes :: proc(t: ^testing.T) {
	h := new_test_holder(t)
	defer holder_free(h, true)
	h.successor = strings.clone("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
	h.successor_until = time.tick_add(time.tick_now(), time.Hour)
	h.sup.launched_at = time.tick_add(time.tick_now(), -SUP_LAUNCH_WAIT - time.Second)
	sup_run(h) // no path, no data dir: nothing launched
	testing.expect_value(t, h.successor, "")
}
