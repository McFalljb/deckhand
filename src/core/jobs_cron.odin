package core

// Job schedules (docs/ATLAS.md §3.1, §3.2): cron in local time (a time a
// DST change skips is skipped, a repeated hour runs once), `every N[smhd]`
// (from the end of the previous run), `at YYYY-MM-DD HH:MM` (once), and
// `manual`. Times are Unix seconds (wall clock); local time goes through
// libc (localtime_r, mktime), so the OS's time zone rules apply.

import "core:strconv"
import "core:strings"
import "core:sys/posix"

Schedule_Kind :: enum u8 {
	Manual,
	Cron,
	Every,
	At,
}

Cron :: struct {
	minute: bit_set[0 ..< 60;u64],
	hour:   bit_set[0 ..< 24;u32],
	dom:    bit_set[1 ..= 31;u32],
	month:  bit_set[1 ..= 12;u16],
	dow:    bit_set[0 ..< 7;u8],
	dom_any, dow_any: bool, // `*`: standard cron ORs the two day fields only when both are restricted
}

Schedule :: struct {
	kind:    Schedule_Kind,
	cron:    Cron,
	every:   i64, // seconds
	at:      i64, // Unix seconds
	min_gap: i64, // cron: the shortest gap between two fire times (the frequency warning)
}

// Parses a schedule; err says what is wrong.
schedule_parse :: proc(text: string) -> (s: Schedule, err: string) {
	t := strings.trim_space(text)
	switch {
	case t == "manual":
		return {kind = .Manual}, ""
	case strings.has_prefix(t, "every "):
		d := parse_duration(strings.trim_space(t[6:]))
		if d < 60 do return {}, `"every N" with m, h or d, at least 1m (e.g. "every 30m")`
		return {kind = .Every, every = d}, ""
	case strings.has_prefix(t, "at "):
		at, ok := parse_local_minute(strings.trim_space(t[3:]))
		if !ok do return {}, `"at YYYY-MM-DD HH:MM" (local time, one that exists)`
		return {kind = .At, at = at}, ""
	}
	c, cerr := cron_parse(t)
	if cerr != "" do return {}, cerr
	s = {kind = .Cron, cron = c}
	// the shortest gap, roughly: the smallest step between fire minutes of one hour, else between hours
	mins := 0
	prev := -1
	gap := i64(24 * 3600)
	for m in 0 ..< 60 do if m in c.minute {
		if prev >= 0 do gap = min(gap, i64(m - prev) * 60)
		prev = m
		mins += 1
	}
	hours := 0
	for h in 0 ..< 24 do if h in c.hour do hours += 1
	if mins > 1 do gap = min(gap, i64(60 - prev + first_in(c.minute)) * 60)
	if mins == 1 && hours > 1 do gap = min(gap, 3600)
	s.min_gap = gap
	return s, ""
}

@(private = "file")
first_in :: proc(set: bit_set[0 ..< 60;u64]) -> int {
	for m in 0 ..< 60 do if m in set do return m
	return 0
}

// "YYYY-MM-DD HH:MM" local -> Unix seconds; false when malformed or it does
// not exist (a DST gap).
parse_local_minute :: proc(s: string) -> (i64, bool) {
	if len(s) != 16 || s[4] != '-' || s[7] != '-' || s[10] != ' ' || s[13] != ':' do return 0, false
	n :: proc(s: string) -> (int, bool) {return strconv.parse_int(s, 10)}
	y, ok1 := n(s[0:4])
	mo, ok2 := n(s[5:7])
	d, ok3 := n(s[8:10])
	h, ok4 := n(s[11:13])
	mi, ok5 := n(s[14:16])
	if !(ok1 && ok2 && ok3 && ok4 && ok5) do return 0, false
	return local_to_unix({y, mo, d, h, mi})
}

Civil :: struct {
	year, month, day, hour, minute: int,
}

// Local civil time of a Unix time, and its weekday (0 = Sunday).
unix_to_local :: proc(t: i64) -> (c: Civil, wday: int) {
	tt := posix.time_t(t)
	tm: posix.tm
	posix.localtime_r(&tt, &tm)
	return {int(tm.tm_year) + 1900, int(tm.tm_mon) + 1, int(tm.tm_mday), int(tm.tm_hour), int(tm.tm_min)}, int(tm.tm_wday)
}

// A local civil minute -> Unix seconds; false when the time does not exist
// (skipped by a DST change) or is out of range.
local_to_unix :: proc(c: Civil) -> (i64, bool) {
	if c.month < 1 || c.month > 12 || c.day < 1 || c.day > days_in_month(c.year, c.month) || c.hour < 0 || c.hour > 23 || c.minute < 0 || c.minute > 59 do return 0, false
	tm := posix.tm{tm_year = i32(c.year - 1900), tm_mon = i32(c.month - 1), tm_mday = i32(c.day), tm_hour = i32(c.hour), tm_min = i32(c.minute), tm_isdst = -1}
	t := posix.mktime(&tm)
	if t == -1 do return 0, false
	back, _ := unix_to_local(i64(t))
	return i64(t), back == c
}

days_in_month :: proc(y, m: int) -> int {
	switch m {
	case 2:          return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
	case 4, 6, 9, 11: return 30
	}
	return 31
}

// Days since 1970-01-01 of a civil date (Howard Hinnant's days_from_civil).
@(private = "file")
days_from_civil :: proc(y_, m, d: int) -> int {
	y := m <= 2 ? y_ - 1 : y_
	era := (y >= 0 ? y : y - 399) / 400
	yoe := y - era * 400
	mp := m > 2 ? m - 3 : m + 9
	doy := (153 * mp + 2) / 5 + d - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

@(private = "file")
civil_from_days :: proc(z_: int) -> (y, m, d: int) {
	z := z_ + 719468
	era := (z >= 0 ? z : z - 146096) / 146097
	doe := z - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y = yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = doy - (153 * mp + 2) / 5 + 1
	m = mp < 10 ? mp + 3 : mp - 9
	if m <= 2 do y += 1
	return
}

// Parses "min hour dom month dow": `*`, `a`, `a-b`, `*/n`, `a-b/n`, lists
// with `,`; dow 0-7 (0 and 7 = Sunday).
cron_parse :: proc(text: string) -> (c: Cron, err: string) {
	f := strings.fields(text, context.temp_allocator)
	if len(f) != 5 do return {}, `cron needs 5 fields "min hour day month weekday" (or "every 30m", "at …", "manual")`
	field :: proc(s: string, lo, hi: int) -> (bits: u64, any: bool, ok: bool) {
		any = s == "*"
		for part in strings.split(s, ",", context.temp_allocator) {
			rng, _, step_s := strings.partition(part, "/")
			step := 1
			if step_s != "" {
				n, sok := strconv.parse_int(step_s, 10)
				if !sok || n <= 0 do return 0, false, false
				step = n
			}
			a, b := lo, hi
			if rng != "*" {
				x, _, y := strings.partition(rng, "-")
				n1, ok1 := strconv.parse_int(x, 10)
				if !ok1 do return 0, false, false
				a, b = n1, n1
				if y != "" {
					n2, ok2 := strconv.parse_int(y, 10)
					if !ok2 do return 0, false, false
					b = n2
				} else if step_s != "" do b = hi
			}
			if a < lo || b > hi || a > b do return 0, false, false
			for v := a; v <= b; v += step do bits |= 1 << uint(v)
		}
		return bits, any, bits != 0
	}
	bits: [5]u64
	anys: [5]bool
	lims := [5][2]int{{0, 59}, {0, 23}, {1, 31}, {1, 12}, {0, 7}}
	names := [5]string{"minute", "hour", "day of month", "month", "weekday"}
	for i in 0 ..< 5 {
		b, a, ok := field(f[i], lims[i][0], lims[i][1])
		if !ok do return {}, strings.concatenate({"cron: bad ", names[i], " field ", f[i]}, context.temp_allocator)
		bits[i], anys[i] = b, a
	}
	if bits[4] & (1 << 7) != 0 do bits[4] = (bits[4] | 1) & 0x7f
	c.minute = transmute(bit_set[0 ..< 60;u64])bits[0]
	c.hour = transmute(bit_set[0 ..< 24;u32])u32(bits[1])
	c.dom = transmute(bit_set[1 ..= 31;u32])u32(bits[2] >> 1)
	c.month = transmute(bit_set[1 ..= 12;u16])u16(bits[3] >> 1)
	c.dow = transmute(bit_set[0 ..< 7;u8])u8(bits[4])
	c.dom_any, c.dow_any = anys[2], anys[4]
	return c, ""
}

@(private = "file")
cron_day :: proc(c: Cron, y, m, d, wday: int) -> bool {
	if m not_in c.month do return false
	dom := d in c.dom
	dow := wday in c.dow
	if c.dom_any && c.dow_any do return true
	if c.dom_any do return dow
	if c.dow_any do return dom
	return dom || dow
}

// The first fire time strictly after `after` (Unix seconds), 0 = none
// within two years. Walks local civil minutes after after's, so a repeated
// hour (DST end) runs once, and a minute that does not exist is skipped.
cron_next :: proc(c: Cron, after: i64) -> i64 {
	start, _ := unix_to_local(after)
	day0 := days_from_civil(start.year, start.month, start.day)
	for k in 0 ..< 366 * 2 {
		y, m, d := civil_from_days(day0 + k)
		wday := ((day0 + k) % 7 + 7 + 4) % 7 // 1970-01-01 was a Thursday
		if !cron_day(c, y, m, d, wday) do continue
		for h in 0 ..< 24 {
			if h not_in c.hour do continue
			if k == 0 && h < start.hour do continue
			for mi in 0 ..< 60 {
				if mi not_in c.minute do continue
				if k == 0 && h == start.hour && mi <= start.minute do continue
				t, exists := local_to_unix({y, m, d, h, mi})
				if !exists || t <= after do continue
				return t
			}
		}
	}
	return 0
}

// The next due time after `now`. every: from `last_end` (the end of the
// previous run; 0 = none yet: now). at: its time once (0 when it passed and
// `fired`). manual: 0.
schedule_next :: proc(s: Schedule, now, last_end: i64) -> i64 {
	switch s.kind {
	case .Manual: return 0
	case .Cron:   return cron_next(s.cron, now)
	case .Every:
		base := last_end > 0 ? last_end : now
		next := base + s.every
		if next <= now do next = now + s.every - (now - base) % s.every
		return next
	case .At: return s.at
	}
	return 0
}

GRACE_MIN :: 2 * 60
GRACE_MAX :: 2 * 3600

// How late a run due at `due` may still start (§3.2): half the job's
// interval clamped to 2 min–2 h (cron: the gap to its next fire time; at:
// 2 h).
grace_window :: proc(s: Schedule, due: i64) -> i64 {
	switch s.kind {
	case .Manual: return GRACE_MAX
	case .At:     return GRACE_MAX
	case .Every:  return clamp(s.every / 2, GRACE_MIN, GRACE_MAX)
	case .Cron:
		next := cron_next(s.cron, due)
		if next == 0 do return GRACE_MAX
		return clamp((next - due) / 2, GRACE_MIN, GRACE_MAX)
	}
	return GRACE_MIN
}

// Whether a run may start at `t` given `hours` (from-to local hours,
// inclusive; from > to wraps past midnight; -1 = any).
in_hours :: proc(from, to: int, t: i64) -> bool {
	if from < 0 do return true
	c, _ := unix_to_local(t)
	if from <= to do return c.hour >= from && c.hour <= to
	return c.hour >= from || c.hour <= to
}
