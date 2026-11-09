package corewire

import "core:testing"

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
		{1, 1, "0.3.0", "", .Ok}, // a development core: generation only
		{1, 2, "0.3.0", "0.3.0", .Core_Newer_Generation},
		{2, 1, "0.3.0", "9.9.9", .Core_Older_Generation},
	}
	for r in rows {
		got := skew_check(r.app_gen, r.core_gen, r.app, r.core, min)
		testing.expectf(t, got == r.want, "app %d/%q core %d/%q: %v, want %v", r.app_gen, r.app, r.core_gen, r.core, got, r.want)
	}
}

// P5: the floor rises with every window seen, an older one is refused, and only an attached
// window's ui request lowers it.
@(test)
window_floor_table :: proc(t: ^testing.T) {
	f := Version{}
	testing.expect_value(t, window_floor_check(f, "0.1.0"), Floor.Allow)
	f = window_floor_raise(f, "0.3.0")
	f = window_floor_raise(f, "0.2.5") // never falls
	testing.expect_value(t, f, Version{0, 3, 0})
	testing.expect_value(t, window_floor_check(f, "0.3.0"), Floor.Allow)
	testing.expect_value(t, window_floor_check(f, "0.2.9"), Floor.Below_Floor)
	_, ok := window_floor_lower(f, "0.2.9", from_attached_ui = false)
	testing.expect(t, !ok, "only an attached window's ui request lowers it")
	lowered, ok2 := window_floor_lower(f, "0.2.9", true)
	testing.expect(t, ok2 && window_floor_check(lowered, "0.2.9") == .Allow)
}
