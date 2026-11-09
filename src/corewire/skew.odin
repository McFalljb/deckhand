package corewire

// Version skew at the framed hello (docs/plans/background-core.md §7.5) and the window floor
// (§5.3 "Window → core", P5), as pure tables. The window runs skew_check on the core's hello
// reply (`generation`, `version`); the core runs window_floor_check on the window's version.
// M4-C wires them in and shows §7.5's messages; M4-E adds the actions (handover, Use this version).
//
// The design puts these in src/trust; they are here because M4-B and M4-A (which owns src/trust)
// run side by side, and they need nothing of trust's. Versions are X.Y.Z release versions from
// the signed Info.plist (§5.3 step 4). A development build has none (version_parse fails): its
// versions are never compared, only its generation.

import "core:strconv"
import "core:strings"

// The framed wire's generation (the hello's `generation`; today's protocol `v`). A breaking
// change of the window ↔ core messages bumps it.
GENERATION :: 1

// The oldest core this window works with. Raise it when the window starts to rely on something an
// older core lacks that `features` cannot gate. 0.1.7 is the first release that can carry a
// separate core (the latest release is 0.1.6, before M1).
CORE_MIN :: Version{0, 1, 7}

Version :: struct {
	major, minor, patch: int,
}

// "X.Y.Z" (digits only, no leading zeros, at most 9 digits each). Anything else, a pre-release
// or a development build's "", is not a version.
version_parse :: proc(s: string) -> (v: Version, ok: bool) {
	parts := strings.split_n(s, ".", 4, context.temp_allocator)
	if len(parts) != 3 do return {}, false
	out: [3]int
	for p, i in parts {
		if len(p) == 0 || len(p) > 9 || (len(p) > 1 && p[0] == '0') do return {}, false
		for ch in p do if ch < '0' || ch > '9' do return {}, false
		n, nok := strconv.parse_int(p, 10)
		if !nok do return {}, false
		out[i] = n
	}
	return {out[0], out[1], out[2]}, true
}

version_less :: proc(a, b: Version) -> bool {
	if a.major != b.major do return a.major < b.major
	if a.minor != b.minor do return a.minor < b.minor
	return a.patch < b.patch
}

// §7.5's rows, as the window sees the core at hello.
Skew :: enum {
	Ok, // same generation, core ≥ the app and ≥ CORE_MIN (or a development build): works
	Core_Older, // same generation, CORE_MIN ≤ core < app: works; a local core is handed over to the bundled one at once
	Core_Below_Min, // same generation, core < CORE_MIN: locally a handover to the bundled core; if that fails, "Deckhand's background core is out of date"
	Core_Newer_Generation, // "Update Deckhand: its background core is newer than this app"
	Core_Older_Generation, // locally: hand over to the bundled core
}

// app_version, core_version: as sent ("" or not X.Y.Z: a development build, not compared).
skew_check :: proc(app_generation, core_generation: i64, app_version, core_version: string, core_min := CORE_MIN) -> Skew {
	if core_generation > app_generation do return .Core_Newer_Generation
	if core_generation < app_generation do return .Core_Older_Generation
	cv, cok := version_parse(core_version)
	if !cok do return .Ok // a development core: only the generation counts
	if version_less(cv, core_min) do return .Core_Below_Min
	av, aok := version_parse(app_version)
	if aok && version_less(cv, av) do return .Core_Older
	return .Ok
}

// ---- the window floor (P5) ----
//
// The core keeps the highest window version that was attached to it. An older window is refused
// ("This Deckhand is older than the one last used with these sessions"), unless an attached
// window lowers the floor (Use this version, asked in the newer window: a ui request). A floor of
// {} is none yet. Development builds (no version) never raise it.

Floor :: enum {
	Allow,
	Below_Floor,
}

window_floor_check :: proc(floor: Version, window_version: string) -> Floor {
	if floor == {} do return .Allow
	v, ok := version_parse(window_version)
	if !ok do return .Below_Floor // a floor is set, and this window has no version to compare
	return version_less(v, floor) ? .Below_Floor : .Allow
}

// A window with this version attached: the floor rises to it, never falls.
window_floor_raise :: proc(floor: Version, window_version: string) -> Version {
	v, ok := version_parse(window_version)
	if !ok || !version_less(floor, v) do return floor
	return v
}

// Use this version (P5): only a ui request from an attached window lowers the floor, and only
// down (to the version of the older window the user picked). ok false: refused, floor unchanged.
window_floor_lower :: proc(floor: Version, to: string, from_attached_ui: bool) -> (Version, bool) {
	if !from_attached_ui do return floor, false
	v, ok := version_parse(to)
	if !ok || version_less(floor, v) do return floor, false
	return v, true
}
