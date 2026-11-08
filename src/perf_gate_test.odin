package main

import "core:testing"
import "core:time"

// perf_expect's verdict (src/cpu_clock_test.odin): over the budget is reported; it fails past
// gate x the budget, or at the budget itself when strict.
@(test)
perf_verdict_gates :: proc(t: ^testing.T) {
	ms :: time.Millisecond
	over, fails := perf_verdict(40 * ms, 50 * ms, PERF_GATE, false)
	testing.expect(t, !over && !fails, "within the budget")
	over, fails = perf_verdict(200 * ms, 50 * ms, PERF_GATE, false)
	testing.expect(t, over && !fails, "4x: reported, not failed (10x gate)")
	over, fails = perf_verdict(200 * ms, 50 * ms, PERF_GATE_USER, false)
	testing.expect(t, over && fails, "4x fails a 3x gate (typing, opening a file)")
	over, fails = perf_verdict(140 * ms, 50 * ms, PERF_GATE_USER, false)
	testing.expect(t, over && !fails, "2.8x is within a 3x gate")
	over, fails = perf_verdict(60 * ms, 50 * ms, PERF_GATE, true)
	testing.expect(t, over && fails, "strict: fails at the budget")
}
