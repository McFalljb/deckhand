package main

// The clock the timing tests measure with (docs/TESTING.md, "Timing tests").

import "core:fmt"
import "core:os"
import "core:sys/posix"
import "core:testing"
import "core:time"

// This thread's CPU time. A timing test that measures single-threaded work with it is not failed
// by a busy machine (other builds, the other test processes of tests/unit.py) the way wall time
// would be: time spent waiting for a core does not count. Work on other threads does not count
// either, so time only work done on the calling thread.
thread_cpu_now :: proc() -> time.Duration {
	ts: posix.timespec
	posix.clock_gettime(.THREAD_CPUTIME_ID, &ts)
	return time.Duration(i64(ts.tv_sec) * i64(time.Second) + i64(ts.tv_nsec))
}

thread_cpu_since :: proc(start: time.Duration) -> time.Duration {return thread_cpu_now() - start}

// A time budget, checked as the perf layer does (docs/TESTING.md, "Timing tests"). The number is
// always printed ("PERF label: took X (budget Y)"; tests/unit.py collects the lines). Over the
// budget it is only reported ("PERF OVER BUDGET", a warning in tests/unit.py's summary), and the
// test fails only past PERF_GATE times the budget: what these tests are for is an accidentally
// quadratic change (tens to thousands of times slower), and a busy machine (other builds, load
// 14-40) has made single runs 2-3x slower, CPU time too (a thread on an efficiency core, caches
// shared with the other processes). DECKHAND_PERF_STRICT=1 (tests/unit.py --perf-strict, on a
// quiet machine) fails at the budget itself. Returns false when the test failed.
PERF_GATE :: 10

perf_expect :: proc(t: ^testing.T, label: string, took, budget: time.Duration, loc := #caller_location) -> bool {
	strict := os.get_env("DECKHAND_PERF_STRICT", context.temp_allocator) == "1"
	ms :: proc(d: time.Duration) -> f64 {return f64(d) / f64(time.Millisecond)}
	if took <= budget {
		fmt.printfln("PERF %s: took %.2f ms (budget %.0f ms)", label, ms(took), ms(budget))
		return true
	}
	fmt.printfln("PERF OVER BUDGET %s: took %.2f ms (budget %.0f ms; fails past %dx%s) at %v", label, ms(took),
		ms(budget), PERF_GATE, strict ? ", strict: fails now" : "", loc)
	gate := strict ? budget : budget * PERF_GATE
	return testing.expectf(t, took <= gate, "%s took %v: over %v (%s)", label, took, gate,
		strict ? "the budget; DECKHAND_PERF_STRICT=1" : "10x the budget: not linear any more?", loc = loc)
}
