package main

// Test mode's backing scale (PI_DESK_SCALE, docs/DEVELOPING.md "Test mode"): unset is 1 on every
// Mac, so a scene's pixel positions do not depend on the display; 1 to 4 otherwise.

import "core:testing"

@(test)
test_scale_default_and_range :: proc(t: ^testing.T) {
	ok :: proc(t: ^testing.T, env: string, want: f64) {
		s, good := test_scale_parse(env)
		testing.expectf(t, good && s == want, "%q: want %v, got %v (ok %v)", env, want, s, good)
	}
	bad :: proc(t: ^testing.T, env: string) {
		_, good := test_scale_parse(env)
		testing.expectf(t, !good, "%q is refused", env)
	}
	ok(t, "", 1)
	ok(t, "1", 1)
	ok(t, "2", 2)
	ok(t, "1.5", 1.5)
	ok(t, " 3 ", 3)
	ok(t, "4", 4)
	bad(t, "0")
	bad(t, "0.5")
	bad(t, "4.5")
	bad(t, "-2")
	bad(t, "two")
	bad(t, "nan")
	bad(t, "inf")
	bad(t, "2x")
}
