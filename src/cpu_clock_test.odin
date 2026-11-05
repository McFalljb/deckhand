package main

// The clock the timing tests measure with (docs/TESTING.md, "Timing tests").

import "core:sys/posix"
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
