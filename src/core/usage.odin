package core

// Quota and usage (docs/GUIDE.md "Usage"; docs/CODEX.md §6b): how much of each coding-agent
// account's plan limits is used, as that agent itself reports it. One entry per account, keyed
// "<source>:<home>" ("codex:/Users/me/.codex", "claude:/Users/me/.claude"). Two sources: Codex
// (usage_codex.odin: `codex app-server`'s account/rateLimits/read) and Claude Code
// (usage_claude.odin: its status line in Claude tabs, live, and a background `get_usage` of a
// headless claude). pi and Antigravity are later sources of the same entries and rows, and so is
// a full Usage page and other machines' accounts.
//
// Rules that keep it safe:
//   - Deckhand never reads a credential and never calls a provider itself: the agent's own
//     program does the fetch with its own sign-in (usage_codex.odin), and only its answer's numbers
//     and labels are kept. An account's id is kept only as a keyed hash (HMAC-SHA256 under this
//     install's own random salt, usage-salt in the data dir, 0600, never in workspace.json): two
//     homes on one account are shown once. It stays in the core: never shown, never on the state
//     wire (STATE_WIRE_SKIPS), never in get_state. Claude Code gives no account id Deckhand keeps:
//     two config folders are two rows.
//   - It reads only while the user can see it: the window says the USAGE section was drawn unfolded
//     (Window_Facts.usage_visible: the left column open on the Sessions tab, By project) and it is
//     not hidden, minimised or occluded; then every USAGE_POLL_EVERY, and USAGE_AFTER_STOP after a
//     Codex turn of that account ended; or when the user asks (Refresh usage, the user's only).
//     One read at a time. A Claude account's numbers also come from its tabs' status line
//     (claude.usage), which starts nothing: a background read of it is due only once those are
//     older than USAGE_POLL_EVERY.
//   - What it last read is saved (workspace.json "usage": numbers and labels), so a restart shows
//     it with its age; the row fades after USAGE_STALE_AFTER, and a window whose reset time passed
//     says so instead of an old percent.
//
// State.usage is the published view (an arena's, rebuilt from the records here); the rows a
// window draws (usage_rows) are made from it, so a window in another process makes the same.

import "base:runtime"
import "core:crypto"
import "core:crypto/hash"
import "core:crypto/hmac"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

Usage_Source :: enum u8 {
	Codex,
	Claude, // later steps: the same entries and rows
	Pi,
	Antigravity,
}
USAGE_SOURCE_NAMES := [Usage_Source]string {
	.Codex       = "codex",
	.Claude      = "claude",
	.Pi          = "pi",
	.Antigravity = "antigravity",
}
// Where the numbers come from, as the hover says (a Claude account's: by its via).
USAGE_SOURCE_FROM := [Usage_Source]string {
	.Codex       = "Codex app-server",
	.Claude      = "Claude Code",
	.Pi          = "pi",
	.Antigravity = "Antigravity",
}

// Which of a source's ways gave an entry's numbers (Claude Code has two; Codex one: None).
Usage_Via :: enum u8 {
	None,
	Status_Line, // a Claude tab's status line (claude.usage): its 5h and 7d windows, live
	Background, // a background read (Claude Code: a headless claude's get_usage)
}
USAGE_VIA_NAMES := [Usage_Via]string {
	.None        = "",
	.Status_Line = "status_line",
	.Background  = "background",
}
USAGE_VIA_FROM := [Usage_Via]string {
	.None        = "",
	.Status_Line = "Claude status line",
	.Background  = "background check",
}

Usage_Status :: enum u8 {
	Unknown, // not read yet
	Ok, // the windows are the last good read
	No_Limits, // signed in with an API key (Claude Code: also Bedrock, Vertex…): no plan limits to show
	Signed_Out,
	Error, // no read has worked yet (a later failure after a good read keeps Ok and sets error)
}
USAGE_STATUS_NAMES := [Usage_Status]string {
	.Unknown    = "unknown",
	.Ok         = "ok",
	.No_Limits  = "no_limits",
	.Signed_Out = "signed_out",
	.Error      = "error",
}

// One limit window as the agent reported it.
Usage_Window :: struct {
	name:         string, // "" = the account's main limit; else another bucket's name (a model's)
	used_percent: f64, // 0..100 (clamped); -1 = not said
	window_mins:  i64, // its length (0 = not said)
	resets_at:    i64, // Unix seconds (0 = not said)
}

// One account's entry (State.usage; an arena's).
Usage_Account :: struct {
	key:          string, // "codex:<home>"
	source:       Usage_Source,
	home:         string, // the account's folder (a Codex home)
	label:        string, // the account's name (Settings › Coding agents)
	plan:         string, // "plus", "pro" … ("" = not said)
	status:       Usage_Status,
	windows:      []Usage_Window, // the main limit's first (at most USAGE_WINDOWS_MAX)
	credits:      string, // "" = not said; "none", "unlimited" or the balance as said
	limit_hit:    bool, // the agent says a limit is reached
	read_at:      i64, // Unix seconds of the last good read (0 = never)
	tried_at:     i64, // the last attempt (0 = none this run)
	error:        string, // why the last attempt failed ("" = it did not)
	account_hash: string, // the account id's salted hash ("" = not said): merges two homes, never shown
	also:         []string, // other homes the same account was read from (merged into this entry)
	reading:      bool, // a read is under way
	via:          Usage_Via, // where the main windows came from (Claude Code; Codex: None)
	extra_at:     i64, // Claude Code: when the background read that gave the model windows ran (0 = none)
	no_limits_why: string, // No_Limits: the sign-in ("" = an API key; Claude Code: "Bedrock"…)
	live_note:    string, // Claude Code: why a running tab of it sends no live numbers ("" = none; usage_claude.odin)
}

USAGE_WINDOWS_MAX :: 8
USAGE_POLL_EVERY :: 5 * 60 // s
USAGE_AFTER_STOP :: 30 // s after a Codex turn of that account ended
USAGE_MIN_GAP :: 60 // s: never two automatic reads of one account closer than this
USAGE_STALE_AFTER :: 60 * 60 // s: the row fades
USAGE_TEXT_MAX :: 80 // bytes of any label the agent sends (plan, credits, a bucket's name)
USAGE_ERROR_MAX :: 160
USAGE_ACCOUNTS_MAX :: 32 // saved and shown, per source

// What a read gave (usage_codex.odin's parse; heap, handed to Usage_Done).
Usage_Read :: struct {
	status:    Usage_Status, // Ok, No_Limits, Signed_Out or Error
	plan:      string,
	credits:   string,
	limit_hit: bool,
	windows:   [dynamic]Usage_Window,
	hash:      string,
	error:     string,
	no_limits_why: string, // No_Limits: the sign-in ("" = an API key; Claude Code: "Bedrock"…)
}

usage_read_free :: proc(r: ^Usage_Read) {
	if r == nil do return
	heap := runtime.heap_allocator()
	delete(r.plan, heap)
	delete(r.credits, heap)
	delete(r.hash, heap)
	delete(r.error, heap)
	delete(r.no_limits_why, heap)
	for w in r.windows do delete(w.name, heap)
	delete(r.windows)
	free(r, heap)
}

// Refresh usage: every account's usage read now (one at a time), whatever the section shows.
Refresh_Usage :: struct {}
// A read finished (internal: the worker's).
Usage_Done :: struct {
	key:  string,
	read: ^Usage_Read `cmd:"-,borrow"`, // handed over (nil: none)
}

// ---- the records (the core's; heap) ----

@(private = "file")
Usage_Record :: struct {
	using a: Usage_Account, // strings and windows heap; also/reading/live_note are the view's only
	next_at: i64, // Unix seconds: the next automatic read is due (0 = as soon as it may)
	forced:  bool, // Refresh usage asked: read whatever the section shows
}

@(private = "file")
usage: struct {
	records:   [dynamic]^Usage_Record,
	arena:     virtual.Arena, // what state.usage points into
	gen:       int, // records changed: publish again
	published: int, // the gen last published (-1: never)
	keys:      string, // heap: the accounts' keys when last published
	checked:   i64, // Unix seconds: the accounts were last compared
	reading:   string, // heap: the key being read ("" = none)
}

@(private = "file")
record_free :: proc(r: ^Usage_Record) {
	heap := runtime.heap_allocator()
	delete(r.key, heap)
	delete(r.home, heap)
	delete(r.label, heap)
	record_data_free(r)
	free(r, heap)
}

@(private = "file")
record_data_free :: proc(r: ^Usage_Record) {
	heap := runtime.heap_allocator()
	delete(r.plan, heap)
	delete(r.credits, heap)
	delete(r.error, heap)
	delete(r.account_hash, heap)
	delete(r.no_limits_why, heap)
	for w in r.windows do delete(w.name, heap)
	delete(r.windows, heap)
	r.plan, r.credits, r.error, r.account_hash, r.windows, r.no_limits_why = "", "", "", "", nil, ""
}

@(private = "file")
record_of :: proc(key: string) -> ^Usage_Record {
	for r in usage.records do if r.key == key do return r
	return nil
}

// An account's key: "<source>:<home>".
usage_key :: proc(source: Usage_Source, home: string, allocator := context.temp_allocator) -> string {
	return strings.concatenate({USAGE_SOURCE_NAMES[source], ":", home}, allocator)
}
// A Codex account's key.
usage_codex_key :: proc(home: string, allocator := context.temp_allocator) -> string {return usage_key(.Codex, home, allocator)}
// A Claude Code account's key (its config folder).
usage_claude_key :: proc(dir: string, allocator := context.temp_allocator) -> string {return usage_key(.Claude, dir, allocator)}

// The account id's hash under this install's salt (usage_hash_with): enough to tell two accounts
// apart, nothing to reverse or to match across installs. "" for no id, or no salt. Any thread.
usage_account_hash :: proc(id: string, allocator := context.temp_allocator) -> string {
	salt, ok := usage_salt()
	if !ok do return ""
	return usage_hash_with(salt[:], id, allocator)
}

@(private = "file")
usage_salt_state: struct {
	once: sync.Once,
	salt: [32]u8,
	ok:   bool,
}

// This install's salt, read (or made) once. Unit tests: a random one in memory, no file.
@(private = "file")
usage_salt :: proc() -> (salt: [32]u8, ok: bool) {
	sync.once_do(&usage_salt_state.once, proc() {
		when ODIN_TEST {
			crypto.rand_bytes(usage_salt_state.salt[:])
			usage_salt_state.ok = true
		} else {
			if data_dir(context.temp_allocator) == "" do return
			usage_salt_state.salt, usage_salt_state.ok = usage_salt_load_from(usage_salt_path())
		}
	})
	return usage_salt_state.salt, usage_salt_state.ok
}

// Where this install's salt for account hashes lives (the data dir; never in workspace.json).
usage_salt_path :: proc() -> string {return fmt.tprintf("%s/usage-salt", strings.trim_right(data_dir(context.temp_allocator), "/"))}

// This install's salt from path, made there (32 random bytes, 0600) the first time. ok false: no
// salt (account hashes then off: no merging).
usage_salt_load_from :: proc(path: string) -> (salt: [32]u8, ok: bool) {
	cpath := strings.clone_to_cstring(path, context.temp_allocator)
	read :: proc(fd: posix.FD, salt: ^[32]u8) -> bool {
		n := posix.read(fd, &salt[0], len(salt))
		extra: [1]u8
		return n == len(salt) && posix.read(fd, &extra[0], 1) == 0 // exactly 32 bytes
	}
	for _ in 0 ..< 2 {
		if fd := posix.open(cpath, {.CLOEXEC, .NOFOLLOW}); fd >= 0 {
			ok = read(fd, &salt)
			posix.close(fd)
			if !ok do salt = {}
			return
		}
		// none yet: made here, only by its creator (O_EXCL); another one's made meanwhile is read
		os.make_directory_all(path[:max(strings.last_index_byte(path, '/'), 0)])
		fd := posix.open(cpath, {.WRONLY, .CREAT, .EXCL, .CLOEXEC, .NOFOLLOW}, {.IRUSR, .IWUSR})
		if fd < 0 {
			if posix.errno() == .EEXIST do continue
			return {}, false
		}
		crypto.rand_bytes(salt[:])
		wrote := posix.write(fd, &salt[0], len(salt)) == len(salt)
		posix.fchmod(fd, {.IRUSR, .IWUSR}) // 0600 whatever the umask
		posix.close(fd)
		if !wrote {
			posix.unlink(cpath)
			return {}, false
		}
		return salt, true
	}
	return {}, false
}

// An account id's hash under a salt: HMAC-SHA256, its first 16 bytes in hex (32 chars). "" for no id.
usage_hash_with :: proc(salt: []u8, id: string, allocator := context.temp_allocator) -> string {
	if id == "" do return ""
	sum: [32]u8
	hmac.sum(hash.Algorithm.SHA256, sum[:], transmute([]u8)id, salt)
	return string(hex.encode(sum[:16], allocator))
}

// ---- pure rules (tests: usage_test.odin) ----

// A percent as the agent sent it, at most 100; -1 (not known) for none: NaN or below 0 (-1 is
// how "not said" is kept, so a saved or a missing one stays "?", never a green 0%).
usage_clamp_percent :: proc(p: f64) -> f64 {
	if math.is_nan(p) || p < 0 do return -1
	return min(p, 100)
}

// A window's short name from its length: 300 -> "5h", 10080 -> "wk", 1440 -> "1d", 45 -> "45m".
usage_window_label :: proc(mins: i64) -> string {
	switch {
	case mins <= 0:              return "limit"
	case mins == 7 * 24 * 60:    return "wk"
	case mins % (7 * 24 * 60) == 0: return fmt.tprintf("%dwk", mins / (7 * 24 * 60))
	case mins % (24 * 60) == 0:  return fmt.tprintf("%dd", mins / (24 * 60))
	case mins % 60 == 0:         return fmt.tprintf("%dh", mins / 60)
	}
	return fmt.tprintf("%dm", mins)
}

Usage_Level :: enum u8 {
	Normal,
	Warn, // from 80%
	Full, // from 95%, or the limit is hit
}

usage_level :: proc(percent: f64, hit: bool) -> Usage_Level {
	if hit || percent >= 95 do return .Full
	if percent >= 80 do return .Warn
	return .Normal
}

// "now", "4m ago", "3h ago", "2d ago" (from Unix seconds).
usage_age_text :: proc(read_at, now: i64) -> string {
	if read_at <= 0 do return ""
	s := max(now - read_at, 0)
	switch {
	case s < 60:          return "now"
	case s < 3600:        return fmt.tprintf("%dm ago", s / 60)
	case s < 24 * 3600:   return fmt.tprintf("%dh ago", s / 3600)
	}
	return fmt.tprintf("%dd ago", s / (24 * 3600))
}

// A reset time, local: "15:40" today (or within the next 18 hours), else "Tue 9:00", else "Nov 30".
usage_clock_text :: proc(t, now: i64) -> string {
	if t <= 0 do return ""
	DAYS :: [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
	MONTHS :: [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
	c, wday := unix_to_local(t)
	n, _ := unix_to_local(now)
	d := t - now
	if (c.year == n.year && c.month == n.month && c.day == n.day) || (d >= 0 && d < 18 * 3600) || (d < 0 && d > -18 * 3600) do return fmt.tprintf("%d:%02d", c.hour, c.minute)
	if d > 0 && d < 7 * 24 * 3600 {
		days := DAYS
		return fmt.tprintf("%s %d:%02d", days[clamp(wday, 0, 6)], c.hour, c.minute)
	}
	months := MONTHS
	return fmt.tprintf("%s %d", months[clamp(c.month - 1, 0, 11)], c.day)
}

// Whether the read is old enough that its row fades.
usage_stale :: proc(read_at, now: i64) -> bool {return read_at > 0 && now - read_at >= USAGE_STALE_AFTER}

// Whether a window's reset time passed since the read: its percent no longer holds.
usage_reset_passed :: proc(w: Usage_Window, read_at, now: i64) -> bool {
	return w.resets_at > 0 && now >= w.resets_at && read_at < w.resets_at
}

// ---- the rows a window draws (the sidebar's USAGE section; later the Usage page) ----

// One bar: a limit window of the account's main limit.
Usage_Bar :: struct {
	label:   string, // "5h", "wk"
	percent: int, // 0..100, rounded; -1 = not known
	level:   Usage_Level,
	reset:   string, // "resets 15:40" ("" = not said)
	passed:  bool, // its reset passed: no new data since (note says so)
	note:    string, // "reset at 15:40, no new data" while passed
}

Usage_Row :: struct {
	key:     string,
	title:   string, // the account's name ("Codex", "Work")
	source:  Usage_Source,
	status:  Usage_Status,
	bars:    []Usage_Bar, // the main limit's windows
	fullest: int, // the bar with the highest percent (-1: none known)
	age:     string, // "4m ago" ("" = never read)
	stale:   bool, // older than USAGE_STALE_AFTER: drawn faded
	note:    string, // in place of bars: "not read yet", "no plan limits", "signed out", "can't read: …"
	line:    string, // the folded section's one line: "5h 82% · 4m ago"
	tip:     string, // the hover: plan, every window, credits, source, home, age
	reading: bool,
	aside:   string, // a quiet line under it: why a running tab gives no live numbers ("managed status line"…)
}

// Every row of entries (temp), at now (Unix seconds). Pure.
usage_rows :: proc(entries: []Usage_Account, now: i64) -> []Usage_Row {
	out := make([dynamic]Usage_Row, 0, len(entries), context.temp_allocator)
	for &e in entries do append(&out, usage_row(e, now))
	return out[:]
}

usage_row :: proc(e: Usage_Account, now: i64) -> Usage_Row {
	r := Usage_Row{key = e.key, title = e.label != "" ? e.label : path_tilde(e.home), source = e.source, status = e.status, fullest = -1, reading = e.reading, aside = e.live_note}
	r.age = usage_age_text(e.read_at, now)
	r.stale = usage_stale(e.read_at, now)
	bars := make([dynamic]Usage_Bar, 0, 2, context.temp_allocator)
	if e.status == .Ok {
		best := -1.0
		for w in e.windows {
			if w.name != "" do continue // another bucket: the hover only
			b := Usage_Bar{label = usage_window_label(w.window_mins), percent = w.used_percent < 0 ? -1 : int(math.round(w.used_percent))}
			if w.resets_at > 0 do b.reset = w.resets_at <= e.read_at ? "reset passed" : fmt.tprintf("resets %s", usage_clock_text(w.resets_at, now)) // Codex said a time already gone
			b.passed = usage_reset_passed(w, e.read_at, now)
			if b.passed do b.note = fmt.tprintf("reset at %s, no new data", usage_clock_text(w.resets_at, now))
			if !b.passed && w.used_percent > best {
				best = w.used_percent
				r.fullest = len(bars)
			}
			append(&bars, b)
		}
		for &b, i in bars do b.level = b.passed || b.percent < 0 ? .Normal : usage_level(f64(b.percent), e.limit_hit && i == r.fullest || b.percent >= 100)
		// two windows of one label (no length said, or the same): told apart, "limit", "limit 2"
		for &b, i in bars {
			n := 1
			for o in bars[:i] do if o.label == b.label do n += 1
			if n > 1 do b.label = fmt.tprintf("%s %d", b.label, n)
		}
	}
	r.bars = bars[:]
	switch e.status {
	case .Unknown:    r.note = e.reading ? "reading…" : "not read yet"
	case .No_Limits:  r.note = fmt.tprintf("no plan limits (%s)", e.no_limits_why != "" ? e.no_limits_why : "API key")
	case .Signed_Out: r.note = "signed out"
	case .Error:      r.note = e.error != "" ? fmt.tprintf("can't read: %s", e.error) : "can't read"
	case .Ok:
		if len(bars) == 0 do r.note = "no limits reported"
		else if e.limit_hit do r.note = "limit reached" // in words too, not only the bar's colour
	}
	// the folded line: the fullest window, else what the row says instead
	if r.fullest >= 0 {
		b := bars[r.fullest]
		r.line = b.percent >= 0 ? fmt.tprintf("%s %d%%", b.label, b.percent) : fmt.tprintf("%s ?", b.label)
	} else if len(bars) > 0 && bars[0].passed {
		r.line = bars[0].note
	} else if len(bars) > 0 {
		r.line = fmt.tprintf("%s ?", bars[0].label) // no percent known
	} else {
		r.line = r.note
	}
	if e.status == .Ok && e.limit_hit && len(bars) > 0 do r.line = fmt.tprintf("limit reached · %s", r.line)
	if r.age != "" do r.line = fmt.tprintf("%s · %s", r.line, r.age)
	r.tip = usage_tip(e, now)
	return r
}

// The hover: "Plus plan · 5h 42%, resets 15:40 · wk 18%, resets Tue 9:00 · credits: none ·
// from Codex app-server · ~/.codex · read 4m ago". Temp.
usage_tip :: proc(e: Usage_Account, now: i64) -> string {
	b := strings.builder_make(context.temp_allocator)
	parts := make([dynamic]string, context.temp_allocator)
	if e.plan != "" do append(&parts, fmt.tprintf("%s plan", usage_plan_name(e.plan)))
	if e.status == .Ok {
		for w in e.windows {
			name := usage_window_label(w.window_mins)
			if w.name != "" do name = fmt.tprintf("%s %s", w.name, name)
			pct := w.used_percent < 0 ? "?" : fmt.tprintf("%d%%", int(math.round(w.used_percent)))
			s := fmt.tprintf("%s %s", name, pct)
			if usage_reset_passed(w, e.read_at, now) do s = fmt.tprintf("%s, reset at %s (no new data)", s, usage_clock_text(w.resets_at, now))
			else if w.resets_at > 0 && w.resets_at <= e.read_at do s = fmt.tprintf("%s, reset passed", s)
			else if w.resets_at > 0 do s = fmt.tprintf("%s, resets %s", s, usage_clock_text(w.resets_at, now))
			append(&parts, s)
		}
		if e.limit_hit do append(&parts, "a limit is reached")
	}
	if e.credits != "" do append(&parts, fmt.tprintf("credits: %s", e.credits))
	switch e.status {
	case .No_Limits:  append(&parts, fmt.tprintf("signed in with %s: no plan limits", e.no_limits_why != "" ? e.no_limits_why : "an API key"))
	case .Signed_Out: append(&parts, "signed out")
	case .Unknown, .Ok, .Error:
	}
	if e.error != "" do append(&parts, fmt.tprintf("last read failed: %s", e.error))
	if e.live_note != "" do append(&parts, e.live_note)
	if e.via != .None {
		append(&parts, fmt.tprintf("from %s", USAGE_VIA_FROM[e.via]))
		// the model windows and spend of an earlier background read, under live main windows
		if e.via == .Status_Line && e.extra_at > 0 && e.extra_at < e.read_at do append(&parts, fmt.tprintf("model limits: background check %s", usage_age_text(e.extra_at, now)))
	} else {
		append(&parts, fmt.tprintf("from %s", USAGE_SOURCE_FROM[e.source]))
	}
	home := path_tilde(e.home)
	for h in e.also do home = fmt.tprintf("%s + %s", home, path_tilde(h))
	append(&parts, home)
	if e.read_at > 0 do append(&parts, fmt.tprintf("read %s", usage_age_text(e.read_at, now)))
	for p, i in parts {
		if i > 0 do strings.write_string(&b, " · ")
		strings.write_string(&b, p)
	}
	return strings.to_string(b)
}

// "plus" -> "Plus", "self_serve_business_prolite" -> "Self serve business prolite".
usage_plan_name :: proc(p: string) -> string {
	if p == "" do return ""
	s, _ := strings.replace_all(p, "_", " ", context.temp_allocator)
	if s[0] >= 'a' && s[0] <= 'z' do s = strings.concatenate({string([]u8{s[0] - 32}), s[1:]}, context.temp_allocator)
	return s
}

// Codex's words with anything shaped like an email address taken out ("an address"): an error may
// name the account, and errors go into State and get_state. Temp.
usage_strip_emails :: proc(s: string) -> string {
	if strings.index_byte(s, '@') < 0 do return s
	sep :: proc(c: u8) -> bool {return c <= ' ' || strings.index_byte(`"'<>()[]{},;:`, c) >= 0}
	b := strings.builder_make(context.temp_allocator)
	i := 0
	for i < len(s) {
		if sep(s[i]) {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		j := i
		for j < len(s) && !sep(s[j]) do j += 1
		word := s[i:j]
		at := strings.index_byte(word, '@')
		if at > 0 && strings.index_byte(word[at + 1:], '.') > 0 do strings.write_string(&b, "(an address)")
		else do strings.write_string(&b, word)
		i = j
	}
	return strings.to_string(b)
}

// ---- the accounts Deckhand reads ----

// One account a source reads (temp).
Usage_Acct :: struct {
	source: Usage_Source,
	dir:    string, // its home: a Codex home, a Claude Code config folder
	label:  string,
}

// The accounts with usage to show, in the section's order: the Codex accounts while Codex is
// installed, then the Claude Code accounts while Claude Code is installed and one of its two ways
// is on (usage_claude_on); at most USAGE_ACCOUNTS_MAX of each. Temp.
@(private = "file")
usage_accounts :: proc() -> []Usage_Acct {
	out := make([dynamic]Usage_Acct, context.temp_allocator)
	if codex_installed() {
		a := claude_accounts(.Codex)
		for x in a[:min(len(a), USAGE_ACCOUNTS_MAX)] do append(&out, Usage_Acct{.Codex, x.dir, x.label})
	}
	if usage_claude_on() {
		a := claude_accounts(.Claude)
		for x in a[:min(len(a), USAGE_ACCOUNTS_MAX)] do append(&out, Usage_Acct{.Claude, x.dir, x.label})
	}
	return out[:]
}

@(private = "file")
usage_record_new :: proc(acct: Usage_Acct) -> ^Usage_Record {
	heap := runtime.heap_allocator()
	r := new(Usage_Record, heap)
	r.key, r.home, r.label, r.source = usage_key(acct.source, acct.dir, heap), strings.clone(acct.dir, heap), strings.clone(acct.label, heap), acct.source
	append(&usage.records, r)
	return r
}

// ---- publishing (State.usage) ----

// The view from the records: one entry per account now configured, in the accounts' order; two
// homes on one account (the same hash, one source) as one entry: the first's row, the newer
// read's numbers, naming the other home.
@(private = "file")
usage_publish :: proc() {
	virtual.arena_free_all(&usage.arena)
	a := virtual.arena_allocator(&usage.arena)
	accts := usage_accounts()
	views := make([dynamic]Usage_Account, 0, len(accts), a)
	merged := make([dynamic]bool, len(accts), context.temp_allocator)
	recs := make([]^Usage_Record, len(accts), context.temp_allocator)
	for acct, i in accts do recs[i] = record_of(usage_key(acct.source, acct.dir))
	for acct, i in accts {
		if merged[i] do continue
		// the row is the first account's (it never moves); its numbers the newest read of any home
		// on the same account (the same hash), the others named in also
		r := recs[i]
		data := i
		also := make([dynamic]string, a)
		key := usage_key(acct.source, acct.dir)
		reading := usage.reading != "" && usage.reading == key
		if r != nil && r.account_hash != "" {
			for j in i + 1 ..< len(accts) {
				o := recs[j]
				if o == nil || merged[j] || accts[j].source != acct.source || o.account_hash != r.account_hash do continue
				merged[j] = true
				append(&also, strings.clone(accts[j].dir, a))
				if o.read_at > recs[data].read_at do data = j
				if usage.reading == usage_key(accts[j].source, accts[j].dir) do reading = true
			}
		}
		v := Usage_Account{key = strings.clone(key, a), source = acct.source, home = strings.clone(acct.dir, a), label = strings.clone(acct.label, a), also = also[:], reading = reading}
		if acct.source == .Claude do v.live_note = strings.clone(usage_claude_live_note(acct.dir), a)
		if rr := recs[data]; rr != nil {
			v.plan, v.status, v.credits, v.limit_hit, v.read_at, v.tried_at = strings.clone(rr.plan, a), rr.status, strings.clone(rr.credits, a), rr.limit_hit, rr.read_at, rr.tried_at
			v.error, v.account_hash = strings.clone(rr.error, a), strings.clone(rr.account_hash, a)
			v.via, v.extra_at, v.no_limits_why = rr.via, rr.extra_at, strings.clone(rr.no_limits_why, a)
			ws := make([]Usage_Window, len(rr.windows), a)
			for w, k in rr.windows do ws[k] = {name = strings.clone(w.name, a), used_percent = w.used_percent, window_mins = w.window_mins, resets_at = w.resets_at}
			v.windows = ws
		}
		append(&views, v)
	}
	state.usage = views[:]
	usage.published = usage.gen
	window_state_changed()
}

// The accounts' keys, one per line (temp): what the view was made from (a Claude account's line
// has its live note: a tab started or gone changes it).
@(private = "file")
usage_keys_now :: proc() -> string {
	b := strings.builder_make(context.temp_allocator)
	for acct in usage_accounts() {
		strings.write_string(&b, USAGE_SOURCE_NAMES[acct.source])
		strings.write_byte(&b, '\t')
		strings.write_string(&b, acct.label)
		strings.write_byte(&b, '\t')
		strings.write_string(&b, acct.dir)
		if acct.source == .Claude {
			strings.write_byte(&b, '\t')
			strings.write_string(&b, usage_claude_live_note(acct.dir))
		}
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// ---- reading ----

when TEST_HOOKS {
	// Unit tests: no read starts unless a test turns this on (and sets DECKHAND_CODEX_CMD or
	// DECKHAND_CLAUDE_CMD).
	usage_reads_in_unit_tests: bool
	// Unit tests: the clock the scheduler reads (0 = the real one).
	usage_test_now: i64
	// Unit tests: an attached window's facts as the scheduler sees them (nil: the real link's).
	usage_test_facts: ^Window_Facts
}

usage_now :: proc() -> i64 {
	when TEST_HOOKS {
		if usage_test_now != 0 do return usage_test_now
	}
	return time.now()._nsec / 1e9
}

// Automatic reads may start: a window (not a hub nor a browser) is attached, not hidden, minimised
// nor occluded, and says it drew the USAGE section unfolded (usage_visible: the left column open on
// the Sessions tab, By project). No facts yet: not.
usage_auto_ok :: proc() -> bool {
	is_window, f := window_link_is_window(), window_facts()
	when TEST_HOOKS {
		if usage_test_facts != nil do is_window, f = true, usage_test_facts
	}
	return is_window && f != nil && !f.hidden && f.usage_visible
}

// A Codex turn of an account ended (its Stop hook): a read of it is due USAGE_AFTER_STOP later.
usage_codex_turn_ended :: proc(account: string) {
	context.allocator = runtime.heap_allocator() // the records outlive any caller's allocator
	key := usage_codex_key(claude_account_dir(account, .Codex))
	r := record_of(key)
	if r == nil do return // not read yet: due anyway
	now := usage_now()
	at := max(now + USAGE_AFTER_STOP, r.tried_at + USAGE_MIN_GAP)
	if r.next_at != 0 && at < r.next_at do r.next_at = at // 0: due already
}

// Each core tick: the view follows the accounts; a read starts when one is due. A Claude account
// is read in the background only while that is on (usage_claude_background_on), and not while its
// tabs' status line gave numbers newer than USAGE_POLL_EVERY (unless the user asked).
usage_tick :: proc() {
	context.allocator = runtime.heap_allocator() // the records outlive any caller's allocator
	if replica_process do return
	now := usage_now()
	if now != usage.checked {
		usage.checked = now
		keys := usage_keys_now()
		if keys != usage.keys {
			delete(usage.keys)
			usage.keys = strings.clone(keys)
			usage.gen += 1
		}
		usage_claude_tabs_tidy()
	}
	if usage.gen != usage.published do usage_publish()
	if usage.reading != "" do return
	auto := usage_auto_ok()
	for acct in usage_accounts() {
		r := record_of(usage_key(acct.source, acct.dir))
		if r == nil {
			if !auto do continue
			r = usage_record_new(acct)
		}
		if r.label != acct.label {
			delete(r.label)
			r.label = strings.clone(acct.label)
		}
		if acct.source == .Claude {
			if !usage_claude_background_on() {
				r.forced = false
				continue
			}
			// live numbers fresher than a poll: the background read waits until they age
			if !r.forced && r.via == .Status_Line && now - r.read_at < USAGE_POLL_EVERY {
				r.next_at = max(r.next_at, r.read_at + USAGE_POLL_EVERY)
				continue
			}
		}
		if !(r.forced || (auto && now >= r.next_at)) do continue
		if usage_read_start(r, now) do break
	}
}

// Starts a read of r on a worker (Usage_Done brings it back). False: none could start.
@(private = "file")
usage_read_start :: proc(r: ^Usage_Record, now: i64) -> bool {
	context.allocator = runtime.heap_allocator() // the records outlive any caller's allocator
	r.forced = false
	r.tried_at = now
	r.next_at = now + USAGE_POLL_EVERY
	when TEST_HOOKS {
		cmd_hook := r.source == .Claude ? Hook.Claude_Cmd : Hook.Codex_Cmd
		if ODIN_TEST && (!usage_reads_in_unit_tests || hook_env(cmd_hook) == "") do return false // tried, nothing run
		if test_mode() && hook_env(cmd_hook) == "" do return false // a scene without a stand-in: no read (never the real codex or claude)
	}
	script := ""
	switch r.source {
	case .Codex:              script = usage_codex_script(r.home)
	case .Claude:             script = usage_claude_script(r.home)
	case .Pi, .Antigravity:   return false
	}
	if script == "" do return false
	usage.reading = strings.clone(r.key)
	usage.gen += 1
	Job :: struct {
		key, script, home: string, // heap
		source:            Usage_Source,
		default_home:      bool, // Codex's own default: initialize need not name it
	}
	job := Job{strings.clone(r.key), script, strings.clone(r.home), r.source, r.source == .Codex && r.home == codex_home()}
	t := thread.create_and_start_with_poly_data(job, proc(j: Job) {
		defer free_all(context.temp_allocator)
		read := j.source == .Claude ? usage_claude_read(j.script) : usage_codex_read(j.script, j.home, j.default_home)
		inbox_submit(Usage_Done{key = j.key, read = read}, {kind = .Internal}) // copied: the inbox's
		delete(j.key)
		delete(j.script)
		delete(j.home)
		if platform.wake != nil do platform.wake()
	}, self_cleanup = true)
	if t == nil {
		delete(job.key)
		delete(job.script)
		delete(job.home)
		delete(usage.reading)
		usage.reading = ""
		return false
	}
	return true
}

// Refresh_Usage and Usage_Done (run_command).
usage_apply :: proc(cmd: Command, caller: Caller) -> (Result, bool) {
	context.allocator = runtime.heap_allocator() // the records outlive any caller's allocator
	#partial switch c in cmd {
	case Refresh_Usage:
		accts := usage_accounts()
		n := 0
		for acct in accts {
			if acct.source == .Claude && !usage_claude_background_on() do continue // its tabs' status line only
			r := record_of(usage_key(acct.source, acct.dir))
			if r == nil do r = usage_record_new(acct)
			r.forced = true
			n += 1
		}
		if n == 0 {
			if len(accts) > 0 do return fail("nothing to read now: Claude Code's usage comes from its tabs' status line (Check Claude usage in the background is off)"), false
			return fail("no account to read usage of: Codex and Claude Code are not installed"), false
		}
		if caller.kind == .UI do window_toast("Reading usage…")
		return {ok = true}, false
	case Usage_Done:
		defer usage_read_free(c.read)
		if usage.reading == c.key {
			delete(usage.reading)
			usage.reading = ""
		}
		usage.gen += 1
		r := record_of(c.key)
		if r == nil || c.read == nil do return {ok = true}, false
		usage_record_apply(r, c.read^)
		return {ok = true}, true
	}
	return fail("not a usage command"), false
}

// A read's outcome into its record: numbers on success; a failure keeps the last good numbers.
// A Claude account's background read (via Background; its model windows' time in extra_at) keeps
// the main windows its tabs' status line sent since the read began.
@(private = "file")
usage_record_apply :: proc(r: ^Usage_Record, read: Usage_Read) {
	heap := runtime.heap_allocator()
	delete(r.error, heap)
	r.error = ""
	now := usage_now()
	switch read.status {
	case .Ok, .No_Limits, .Signed_Out:
		// live numbers that came in while this read ran are newer than its main windows
		live := r.source == .Claude && read.status == .Ok && r.via == .Status_Line && r.read_at >= r.tried_at && r.tried_at > 0
		kept: [dynamic]Usage_Window
		kept_credits := ""
		kept_at := r.read_at
		if live {
			kept = make([dynamic]Usage_Window, 0, 2, heap)
			for w in r.windows do if w.name == "" do append(&kept, Usage_Window{name = "", used_percent = w.used_percent, window_mins = w.window_mins, resets_at = w.resets_at})
			kept_credits = strings.clone(r.credits, heap)
		}
		record_data_free(r)
		r.status = read.status
		r.plan = strings.clone(cut_utf8(read.plan, USAGE_TEXT_MAX), heap)
		r.credits = strings.clone(cut_utf8(read.credits, USAGE_TEXT_MAX), heap)
		r.account_hash = strings.clone(read.hash, heap)
		r.no_limits_why = strings.clone(cut_utf8(read.no_limits_why, USAGE_TEXT_MAX), heap)
		r.limit_hit = read.limit_hit
		r.via = r.source == .Claude ? .Background : .None
		r.extra_at = 0
		if read.status == .Ok {
			ws := make([dynamic]Usage_Window, 0, len(read.windows), heap)
			if live do append(&ws, ..kept[:])
			for w in read.windows[:min(len(read.windows), USAGE_WINDOWS_MAX)] {
				if live && w.name == "" do continue
				if len(ws) >= USAGE_WINDOWS_MAX do break
				append(&ws, Usage_Window{name = strings.clone(cut_utf8(w.name, USAGE_TEXT_MAX), heap), used_percent = usage_clamp_percent(w.used_percent), window_mins = w.window_mins, resets_at = w.resets_at})
			}
			r.windows = ws[:]
			if r.source == .Claude do r.extra_at = now
		}
		r.read_at = now
		if live {
			delete(kept)
			r.via, r.read_at = .Status_Line, kept_at
			r.limit_hit = usage_main_full(r.windows)
			if kept_credits != "" {
				delete(r.credits, heap)
				r.credits = kept_credits
			} else do delete(kept_credits, heap)
		}
	case .Error, .Unknown:
		r.error = strings.clone(cut_utf8(usage_strip_emails(read.error != "" ? read.error : "no answer"), USAGE_ERROR_MAX), heap)
		if r.status == .Unknown do r.status = .Error
	}
}

// Whether a main window is at 100% (Claude Code says no limit hit in words: a full window is one).
usage_main_full :: proc(ws: []Usage_Window) -> bool {
	for w in ws do if w.name == "" && w.used_percent >= 100 do return true
	return false
}

// A Claude tab's status line numbers (claude.usage; usage_claude.odin checked them) into its
// account's record: its main windows (5h, 7d) and spend replace the last ones; the model windows
// of a background read stay. Within one window (the same length and reset time) a percent never
// goes down: one tab's older numbers (another tab of the account, an idle one, a background read
// newer than them) never hide newer ones. A tab's repeats of its own last numbers never get here
// (usage_claude_report_apply), so they leave read_at as it was and the background check falls due.
usage_claude_live :: proc(dir: string, label: string, live_in: Usage_Live) {
	live := live_in
	context.allocator = runtime.heap_allocator() // the records outlive any caller's allocator
	heap := runtime.heap_allocator()
	if live.n == 0 && live.spend == "" do return // nothing said yet (no API answer, or no plan limits)
	r := record_of(usage_claude_key(dir))
	if r == nil do r = usage_record_new({.Claude, dir, label})
	now := usage_now()
	ws := make([dynamic]Usage_Window, 0, USAGE_WINDOWS_MAX, heap)
	for w in live.windows[:live.n] {
		pct := usage_clamp_percent(w.used_percent)
		if r.status == .Ok && w.resets_at > 0 do for old in r.windows do if old.name == "" && old.window_mins == w.window_mins && abs(old.resets_at - w.resets_at) <= USAGE_SAME_RESET {
			pct = max(pct, old.used_percent) // the same window: never lower
		}
		append(&ws, Usage_Window{name = "", used_percent = pct, window_mins = w.window_mins, resets_at = w.resets_at})
	}
	for w in r.windows {
		if w.name != "" && len(ws) < USAGE_WINDOWS_MAX do append(&ws, w) // moved
		else do delete(w.name, heap)
	}
	delete(r.windows, heap)
	r.windows = ws[:]
	if live.spend != "" {
		delete(r.credits, heap)
		r.credits = strings.clone(cut_utf8(live.spend, USAGE_TEXT_MAX), heap)
	}
	if r.status != .Ok {
		delete(r.no_limits_why, heap)
		r.no_limits_why = ""
	}
	delete(r.error, heap)
	r.error = ""
	r.status = .Ok
	r.limit_hit = usage_main_full(r.windows)
	r.read_at, r.via = now, .Status_Line
	usage.gen += 1
}

USAGE_SAME_RESET :: 60 // s: two reset times this close are one window's (the status line's and get_usage's are rounded apart)

// ---- saved (workspace.json "usage": numbers and labels; persist.odin) ----

usage_json :: proc(b: ^strings.Builder) {
	strings.write_byte(b, '[')
	n: [Usage_Source]int
	first := true
	codex, claude := claude_accounts(.Codex), claude_accounts(.Claude) // removed accounts' reads are not kept (installed or not)
	for r in usage.records {
		if r.read_at == 0 || n[r.source] >= USAGE_ACCOUNTS_MAX do continue // nothing read: nothing to show after a restart
		still := false
		#partial switch r.source {
		case .Codex:  for a in codex do if usage_codex_key(a.dir) == r.key do still = true
		case .Claude: for a in claude do if usage_claude_key(a.dir) == r.key do still = true
		}
		if !still do continue
		if !first do strings.write_byte(b, ',')
		first = false
		n[r.source] += 1
		strings.write_string(b, `{"key":`)
		json_quote(b, r.key)
		fmt.sbprintf(b, `,"source":"%s","home":`, USAGE_SOURCE_NAMES[r.source])
		json_quote(b, r.home)
		strings.write_string(b, `,"label":`)
		json_quote(b, r.label)
		strings.write_string(b, `,"plan":`)
		json_quote(b, r.plan)
		fmt.sbprintf(b, `,"status":"%s","credits":`, USAGE_STATUS_NAMES[r.status])
		json_quote(b, r.credits)
		fmt.sbprintf(b, `,"limit_hit":%v,"read_at":%d,"account_hash":`, r.limit_hit, r.read_at)
		json_quote(b, r.account_hash)
		if r.via != .None do fmt.sbprintf(b, `,"via":"%s","extra_at":%d`, USAGE_VIA_NAMES[r.via], r.extra_at)
		if r.no_limits_why != "" {
			strings.write_string(b, `,"no_limits_why":`)
			json_quote(b, r.no_limits_why)
		}
		strings.write_string(b, `,"windows":[`)
		for w, i in r.windows {
			if i > 0 do strings.write_byte(b, ',')
			strings.write_string(b, `{"name":`)
			json_quote(b, w.name)
			fmt.sbprintf(b, `,"used_percent":%.1f,"window_mins":%d,"resets_at":%d}}`, w.used_percent, w.window_mins, w.resets_at)
		}
		strings.write_string(b, "]}")
	}
	strings.write_byte(b, ']')
}

// The saved entries back (persist.odin's restore): Codex and Claude Code ones only, absolute
// homes, at most USAGE_ACCOUNTS_MAX of each source; anything else in them is ignored.
usage_restore :: proc(v: json.Value) {
	context.allocator = runtime.heap_allocator() // the records outlive any caller's allocator
	list, ok := v.(json.Array)
	if !ok do return
	heap := runtime.heap_allocator()
	for r in usage.records do record_free(r)
	clear(&usage.records)
	str :: proc(o: json.Object, k: string) -> string {return string(o[k].(json.String) or_else "")}
	num :: proc(o: json.Object, k: string, none := 0.0) -> f64 {
		#partial switch x in o[k] {
		case json.Integer: return f64(x)
		case json.Float:   return f64(x)
		}
		return none
	}
	now := usage_now()
	n: [Usage_Source]int
	for x in list {
		o, is := x.(json.Object)
		if !is do continue
		source: Usage_Source
		switch str(o, "source") {
		case "codex":  source = .Codex
		case "claude": source = .Claude
		case:          continue
		}
		if n[source] >= USAGE_ACCOUNTS_MAX do continue
		home := str(o, "home")
		key := usage_key(source, home)
		if !strings.has_prefix(home, "/") || str(o, "key") != key || record_of(key) != nil do continue
		st := Usage_Status.Unknown
		for name, x in USAGE_STATUS_NAMES do if name == str(o, "status") do st = x
		if st == .Unknown || st == .Error do continue // nothing worth showing after a restart
		r := new(Usage_Record, heap)
		r.key, r.home, r.source, r.status = strings.clone(key, heap), strings.clone(home, heap), source, st
		r.label = strings.clone(cut_utf8(str(o, "label"), USAGE_TEXT_MAX), heap)
		r.plan = strings.clone(cut_utf8(str(o, "plan"), USAGE_TEXT_MAX), heap)
		r.credits = strings.clone(cut_utf8(str(o, "credits"), USAGE_TEXT_MAX), heap)
		if st == .No_Limits do r.no_limits_why = strings.clone(cut_utf8(str(o, "no_limits_why"), USAGE_TEXT_MAX), heap)
		if h := str(o, "account_hash"); len(h) <= 64 && source == .Codex do r.account_hash = strings.clone(h, heap)
		r.limit_hit = bool(o["limit_hit"].(json.Boolean) or_else false)
		r.read_at = min(i64(num(o, "read_at")), now) // a clock set back: never a read from the future
		r.next_at = r.read_at + USAGE_POLL_EVERY
		if source == .Claude {
			for name, x in USAGE_VIA_NAMES do if name != "" && name == str(o, "via") do r.via = x
			if r.via == .None do r.via = .Background
			r.extra_at = clamp(i64(num(o, "extra_at")), 0, r.read_at)
		}
		if st == .Ok {
			ws, _ := o["windows"].(json.Array)
			list := make([dynamic]Usage_Window, 0, min(len(ws), USAGE_WINDOWS_MAX), heap)
			for wv in ws {
				if len(list) >= USAGE_WINDOWS_MAX do break
				w, wok := wv.(json.Object)
				if !wok do continue
				append(&list, Usage_Window{name = strings.clone(cut_utf8(str(w, "name"), USAGE_TEXT_MAX), heap), used_percent = usage_clamp_percent(num(w, "used_percent", -1)), window_mins = max(i64(num(w, "window_mins")), 0), resets_at = max(i64(num(w, "resets_at")), 0)})
			}
			r.windows = list[:]
		}
		append(&usage.records, r)
		n[source] += 1
	}
	usage.gen += 1
}

when TEST_HOOKS {
	// Tests: every record and the view dropped.
	usage_reset_for_test :: proc() {
		context.allocator = runtime.heap_allocator() // the records outlive any caller's allocator
		for r in usage.records do record_free(r)
		clear(&usage.records)
		delete(usage.reading)
		usage.reading = ""
		delete(usage.keys)
		usage.keys = ""
		usage.checked = 0
		usage.gen += 1
		usage_claude_tabs_reset_for_test()
		usage_publish()
	}
	// Tests: a read's outcome for an account's home, as Usage_Done brings it (now: usage_now).
	usage_apply_for_test :: proc(home: string, read: Usage_Read, source := Usage_Source.Codex) {
		context.allocator = runtime.heap_allocator() // the records outlive any caller's allocator
		r := record_of(usage_key(source, home))
		if r == nil do r = usage_record_new({source, home, ""})
		r.tried_at = usage_now() // as a read that started now
		r.next_at = r.tried_at + USAGE_POLL_EVERY
		usage_record_apply(r, read)
		usage.gen += 1
		usage_publish()
	}
	// Tests: when the next automatic read of home is due (0 = no record).
	usage_next_at_for_test :: proc(home: string, source := Usage_Source.Codex) -> (next_at: i64, forced: bool) {
		r := record_of(usage_key(source, home))
		if r == nil do return 0, false
		return r.next_at, r.forced
	}
	// Tests: a read's outcome as above, for a read that began at tried_at.
	usage_apply_for_test_at :: proc(home: string, read: Usage_Read, tried_at: i64, source := Usage_Source.Claude) {
		context.allocator = runtime.heap_allocator() // the records outlive any caller's allocator
		r := record_of(usage_key(source, home))
		if r == nil do r = usage_record_new({source, home, ""})
		r.tried_at = tried_at
		usage_record_apply(r, read)
		usage.gen += 1
		usage_publish()
	}
	usage_publish_for_test :: proc() {usage_publish()}
	usage_reading_for_test :: proc() -> string {return usage.reading}
}

// get_state's "usage" (json_write.odin): each entry as State.usage has it, without its account
// hash; and each row's words as a window draws them (rows), so scripts check what is shown.
usage_snapshot_json :: proc(b: ^strings.Builder, entries: []Usage_Account) {
	now := usage_now()
	strings.write_string(b, `,"usage":[`)
	for e, i in entries {
		if i > 0 do strings.write_byte(b, ',')
		r := usage_row(e, now)
		strings.write_string(b, `{"key":`)
		json_quote(b, e.key)
		fmt.sbprintf(b, `,"source":"%s","home":`, USAGE_SOURCE_NAMES[e.source])
		json_quote(b, e.home)
		strings.write_string(b, `,"label":`)
		json_quote(b, e.label)
		strings.write_string(b, `,"plan":`)
		json_quote(b, e.plan)
		fmt.sbprintf(b, `,"status":"%s","credits":`, USAGE_STATUS_NAMES[e.status])
		json_quote(b, e.credits)
		fmt.sbprintf(b, `,"limit_hit":%v,"read_at":%d,"tried_at":%d,"reading":%v,"stale":%v,"error":`, e.limit_hit, e.read_at, e.tried_at, e.reading, r.stale)
		json_quote(b, e.error)
		fmt.sbprintf(b, `,"via":"%s","extra_at":%d,"no_limits_why":`, USAGE_VIA_NAMES[e.via], e.extra_at)
		json_quote(b, e.no_limits_why)
		strings.write_string(b, `,"live_note":`)
		json_quote(b, e.live_note)
		strings.write_string(b, `,"also":[`)
		for h, k in e.also {
			if k > 0 do strings.write_byte(b, ',')
			json_quote(b, h)
		}
		strings.write_string(b, `],"windows":[`)
		for w, k in e.windows {
			if k > 0 do strings.write_byte(b, ',')
			strings.write_string(b, `{"name":`)
			json_quote(b, w.name)
			fmt.sbprintf(b, `,"used_percent":%d,"window_mins":%d,"resets_at":%d}}`, w.used_percent < 0 ? -1 : int(math.round(w.used_percent)), w.window_mins, w.resets_at)
		}
		strings.write_string(b, `],"bars":[`)
		for x, k in r.bars {
			if k > 0 do strings.write_byte(b, ',')
			strings.write_string(b, `{"label":`)
			json_quote(b, x.label)
			fmt.sbprintf(b, `,"percent":%d,"level":"%s","passed":%v,"note":`, x.percent, strings.to_lower(fmt.tprint(x.level), context.temp_allocator), x.passed)
			json_quote(b, x.note)
			strings.write_byte(b, '}')
		}
		strings.write_string(b, `],"note":`)
		json_quote(b, r.note)
		strings.write_string(b, `,"line":`)
		json_quote(b, r.line)
		strings.write_byte(b, '}')
	}
	strings.write_byte(b, ']')
}
