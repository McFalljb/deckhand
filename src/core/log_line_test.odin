package core

import "core:strings"
import "core:testing"
import "core:time"

// core.log's lines start with the time, in UTC, to the second (#108).
@(test)
log_stamp_format :: proc(t: ^testing.T) {
	testing.expect_value(t, log_stamp(time.unix(0, 0)), "1970-01-01T00:00:00Z")
	testing.expect_value(t, log_stamp(time.unix(1_794_502_201, 999_999_999)), "2026-11-12T16:50:01Z")
	testing.expect(t, strings.has_suffix(log_stamp(time.now()), "Z"))
}
