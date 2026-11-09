package corewire

import "core:testing"

@(test)
version_parse_table :: proc(t: ^testing.T) {
	Row :: struct {
		s:  string,
		v:  Version,
		ok: bool,
	}
	rows := [?]Row {
		{"0.1.7", {0, 1, 7}, true},
		{"12.0.345", {12, 0, 345}, true},
		{"", {}, false}, // a development build
		{"0.1", {}, false},
		{"0.1.7.1", {}, false},
		{"v0.1.7", {}, false},
		{"0.01.7", {}, false},
		{"0.1.7-beta", {}, false},
		{"0.1.x", {}, false},
		{"1234567890.0.0", {}, false},
		{"0..7", {}, false},
	}
	for r in rows {
		v, ok := version_parse(r.s)
		testing.expectf(t, ok == r.ok && v == r.v, "%q: %v %v", r.s, v, ok)
	}
	testing.expect(t, version_less({0, 1, 9}, {0, 2, 0}) && version_less({0, 9, 9}, {1, 0, 0}) && !version_less({1, 0, 0}, {1, 0, 0}))
}

// §7.5's rows.
@(test)
skew_check_table :: proc(t: ^testing.T) {
	Row :: struct {
		app_gen, core_gen: i64,
		app, core:         string,
		want:              Skew,
	}
	min := Version{0, 2, 0}
	rows := [?]Row {
		{1, 1, "0.3.0", "0.3.0", .Ok},
		{1, 1, "0.3.0", "0.4.1", .Ok}, // a newer core of the same generation works
		{1, 1, "0.3.0", "0.2.0", .Core_Older}, // ≥ CORE_MIN, older: handed over at once (locally)
		{1, 1, "0.3.0", "0.1.9", .Core_Below_Min},
		{1, 1, "", "0.1.9", .Core_Below_Min}, // a development window still refuses a release core below CORE_MIN
		{1, 1, "0.3.0", "", .Ok}, // a development core: generation only
		{1, 1, "", "", .Ok},
		{1, 2, "0.3.0", "0.3.0", .Core_Newer_Generation},
		{1, 2, "0.3.0", "", .Core_Newer_Generation},
		{2, 1, "0.3.0", "9.9.9", .Core_Older_Generation},
	}
	for r in rows {
		got := skew_check(r.app_gen, r.core_gen, r.app, r.core, min)
		testing.expectf(t, got == r.want, "app %d/%q core %d/%q: %v, want %v", r.app_gen, r.app, r.core_gen, r.core, got, r.want)
	}
	testing.expect(t, !version_less(CORE_MIN, {0, 1, 7}), "CORE_MIN is a release version")
}

// P5: the floor rises with every window seen, an older one is refused, and only an attached
// window's ui request lowers it.
@(test)
window_floor_table :: proc(t: ^testing.T) {
	f := Version{}
	testing.expect_value(t, window_floor_check(f, "0.1.0"), Floor.Allow)
	testing.expect_value(t, window_floor_check(f, ""), Floor.Allow) // no floor yet: a development window too
	f = window_floor_raise(f, "0.3.0")
	testing.expect_value(t, f, Version{0, 3, 0})
	f = window_floor_raise(f, "0.2.5") // never falls
	f = window_floor_raise(f, "") // a development window does not raise it
	testing.expect_value(t, f, Version{0, 3, 0})
	testing.expect_value(t, window_floor_check(f, "0.3.0"), Floor.Allow)
	testing.expect_value(t, window_floor_check(f, "0.4.0"), Floor.Allow)
	testing.expect_value(t, window_floor_check(f, "0.2.9"), Floor.Below_Floor)
	testing.expect_value(t, window_floor_check(f, ""), Floor.Below_Floor)
	testing.expect_value(t, window_floor_check(f, "garbage"), Floor.Below_Floor)
	lowered, ok := window_floor_lower(f, "0.2.9", from_attached_ui = false)
	testing.expect(t, !ok && lowered == f, "only an attached window's ui request lowers it")
	lowered, ok = window_floor_lower(f, "0.4.0", true)
	testing.expect(t, !ok && lowered == f, "lowering never raises")
	lowered, ok = window_floor_lower(f, "", true)
	testing.expect(t, !ok, "to a version")
	lowered, ok = window_floor_lower(f, "0.2.9", true)
	testing.expect(t, ok && lowered == Version{0, 2, 9})
	testing.expect_value(t, window_floor_check(lowered, "0.2.9"), Floor.Allow)
}
