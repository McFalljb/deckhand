package core

// Quota and usage (usage.odin, usage_codex.odin): Codex's app-server answers parsed loosely (the
// fixtures follow its generated schema, GetAccountRateLimitsResponse), percents clamped, the
// staleness and reset rules, the rows a window draws, keys and the merge of two homes on one
// account, the saved entries back after a restart, the scheduler's due times, and one exchange
// with a stand-in app-server (a shell line: never a real codex).

import "base:runtime"
import "core:crypto/sha2"
import "core:encoding/hex"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import jg "../jsonguard"

// A release build (-define:DECKHAND_TEST_HOOKS=false) compiles _test files too, and these tests
// use helpers that exist only with the test hooks: the whole file is behind them.
when TEST_HOOKS {

@(private = "file")
UT_NOW :: i64(1_795_000_000)

@(private = "file")
ut_dir :: proc(name: string) -> string {
	d := fmt.tprintf("%s/ut-%s", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), name)
	os.make_directory_all(d)
	return d
}

// A fresh setup: a fake HOME, Codex "installed", no records; homes: Codex accounts added (the
// default is HOME/.codex).
@(private = "file")
ut_reset :: proc(homes: ..string) -> (default_home: string) {
	home := ut_dir("home")
	os.set_env("HOME", home)
	os.unset_env("CODEX_HOME")
	os.make_directory_all(fmt.tprintf("%s/.codex", home))
	harness_found[.Codex] = .Yes
	harness_found[.Claude] = .No // Claude Code's rows: usage_claude_test.odin
	clear(&state.settings.codex_accounts)
	for h in homes {
		os.make_directory_all(h)
		append(&state.settings.codex_accounts, Claude_Account_Setting{dir = strings.clone(h, runtime.heap_allocator()), added = true})
	}
	claude_accounts_gen += 1
	usage_test_now = UT_NOW
	usage_reset_for_test()
	return codex_home()
}

@(private = "file")
ut_done :: proc() {
	harness_found[.Codex] = .Unknown
	harness_found[.Claude] = .Unknown
	clear(&state.settings.codex_accounts)
	claude_accounts_gen += 1
	usage_reset_for_test()
	usage_test_now = 0
}

@(private = "file")
ut_ok :: proc(hash := "", p5 := 42.0, pwk := 18.0, r5: i64 = UT_NOW + 3 * 3600) -> Usage_Read {
	r := Usage_Read{status = .Ok, plan = "plus", credits = "none", hash = hash}
	r.windows = make([dynamic]Usage_Window, context.temp_allocator)
	append(&r.windows, Usage_Window{used_percent = p5, window_mins = 300, resets_at = r5})
	append(&r.windows, Usage_Window{used_percent = pwk, window_mins = 10080, resets_at = UT_NOW + 4 * 86400})
	return r
}

// initialize's answer for a home.
@(private = "file")
init_reply :: proc(home: string) -> string {
	return strings.concatenate({`{"id":1,"result":{"codexHome":"`, home, `","platformFamily":"unix","platformOs":"macos","userAgent":"codex"}}`}, context.temp_allocator)
}

@(test)
usage_parse_full_answer :: proc(t: ^testing.T) {
	read := `{"id":2,"result":{"rateLimits":{"limitId":"codex","limitName":null,"planType":"pro","primary":{"usedPercent":42,"windowDurationMins":300,"resetsAt":1795010800},"secondary":{"usedPercent":18.4,"windowDurationMins":10080,"resetsAt":1795300000},"credits":{"hasCredits":true,"unlimited":false,"balance":"12.50"},"rateLimitReachedType":null,"individualLimit":null,"futureField":[1,{"x":2}]},"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":42}},"codex_spark":{"limitId":"codex_spark","limitName":"GPT-5 Spark","primary":{"usedPercent":7,"windowDurationMins":300}}},"accountId":"acct-123","rateLimitResetCredits":{"availableCount":0},"ordinaryUsageAllowed":true,"rateLimitUpsell":{"anything":"goes"}}}`
	r := usage_codex_parse(init_reply("/h/.codex"), read, "/h/.codex")
	defer usage_read_free(r)
	testing.expect_value(t, r.status, Usage_Status.Ok)
	testing.expect_value(t, r.plan, "pro")
	testing.expect_value(t, r.credits, "12.50")
	testing.expect_value(t, r.limit_hit, false)
	testing.expect_value(t, len(r.windows), 3)
	testing.expect_value(t, r.windows[0].used_percent, 42.0)
	testing.expect_value(t, r.windows[0].window_mins, i64(300))
	testing.expect_value(t, r.windows[0].resets_at, i64(1795010800))
	testing.expect_value(t, r.windows[1].window_mins, i64(10080))
	testing.expect_value(t, r.windows[2].name, "GPT-5 Spark") // another bucket, named; the main one not twice
	testing.expect_value(t, r.windows[2].resets_at, i64(0))
	// the account id: only its salted hash, never the id itself
	testing.expect_value(t, len(r.hash), 32)
	testing.expect(t, !strings.contains(r.hash, "acct"), "a hash, not the id")
	testing.expect_value(t, r.hash, usage_account_hash("acct-123"))
	testing.expect(t, usage_account_hash("acct-124") != r.hash)
}

@(test)
usage_parse_loose :: proc(t: ^testing.T) {
	init := init_reply("/h")
	// missing fields: not said; out of range: clamped or dropped; a reached limit
	{
		r := usage_codex_parse(init, `{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":150},"secondary":{"usedPercent":-3,"windowDurationMins":-5,"resetsAt":-1},"rateLimitReachedType":"rate_limit_reached","credits":{"hasCredits":false,"unlimited":true}}}}`, "/h")
		defer usage_read_free(r)
		testing.expect_value(t, r.status, Usage_Status.Ok)
		testing.expect_value(t, len(r.windows), 2)
		testing.expect_value(t, r.windows[0].used_percent, 100.0)
		testing.expect_value(t, r.windows[0].window_mins, i64(0))
		testing.expect_value(t, r.windows[1].used_percent, -1.0) // below 0: not a percent (unknown, never 0%)
		testing.expect_value(t, r.windows[1].window_mins, i64(0))
		testing.expect_value(t, r.windows[1].resets_at, i64(0))
		testing.expect(t, r.limit_hit)
		testing.expect_value(t, r.credits, "unlimited")
		testing.expect_value(t, r.plan, "")
		testing.expect_value(t, r.hash, "")
	}
	// a window without its percent: -1 (not said); wrong types ignored
	{
		r := usage_codex_parse(init, `{"id":2,"result":{"rateLimits":{"primary":{"windowDurationMins":"300"},"secondary":null,"planType":7,"credits":"x"}}}`, "/h")
		defer usage_read_free(r)
		testing.expect_value(t, r.status, Usage_Status.Ok)
		testing.expect_value(t, len(r.windows), 1)
		testing.expect_value(t, r.windows[0].used_percent, -1.0)
		testing.expect_value(t, r.plan, "")
		testing.expect_value(t, r.credits, "")
	}
	// no rateLimits at all: read, nothing to show
	{
		r := usage_codex_parse(init, `{"id":2,"result":{}}`, "/h")
		defer usage_read_free(r)
		testing.expect_value(t, r.status, Usage_Status.Ok)
		testing.expect_value(t, len(r.windows), 0)
	}
	// more windows than kept: capped
	{
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":1}},"rateLimitsByLimitId":{`)
		for i in 0 ..< 20 do fmt.sbprintf(&b, `%s"b%02d":{{"primary":{{"usedPercent":%d}}}}`, i > 0 ? "," : "", i, i)
		strings.write_string(&b, "}}}")
		r := usage_codex_parse(init, strings.to_string(b), "/h")
		defer usage_read_free(r)
		testing.expect_value(t, len(r.windows), USAGE_WINDOWS_MAX)
	}
}

@(test)
usage_parse_errors :: proc(t: ^testing.T) {
	init := init_reply("/h")
	cases := [?]struct {
		reply: string,
		want:  Usage_Status,
		err:   string,
	} {
		{`{"id":2,"error":{"code":-32600,"message":"chatgpt authentication required to read rate limits"}}`, .No_Limits, ""},
		{`{"id":2,"error":{"code":-32600,"message":"codex account authentication required to read rate limits"}}`, .Signed_Out, ""},
		{`{"id":2,"error":{"code":-32603,"message":"failed to fetch codex rate limits: 503\nmore"}}`, .Error, "failed to fetch codex rate limits: 503 more"},
		{`{"id":2,"error":{"code":-32601}}`, .Error, "Codex refused the request"},
		{`not json`, .Error, "Codex's answer was not JSON"},
		{`{"id":2,"result":[1]}`, .Error, "Codex's answer had no result"},
	}
	for c in cases {
		r := usage_codex_parse(init, c.reply, "/h")
		testing.expectf(t, r.status == c.want, "%s: %v", c.reply, r.status)
		if c.err != "" do testing.expect_value(t, r.error, c.err)
		usage_read_free(r)
	}
	// the server answered for another home (a login profile that moved CODEX_HOME): not used
	r := usage_codex_parse(init_reply("/other"), `{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5}}}}`, "/h")
	testing.expect_value(t, r.status, Usage_Status.Error)
	testing.expect_value(t, r.error, "Codex answered for another home")
	usage_read_free(r)
}

@(test)
usage_rules :: proc(t: ^testing.T) {
	testing.expect_value(t, usage_window_label(300), "5h")
	testing.expect_value(t, usage_window_label(10080), "wk")
	testing.expect_value(t, usage_window_label(20160), "2wk")
	testing.expect_value(t, usage_window_label(1440), "1d")
	testing.expect_value(t, usage_window_label(45), "45m")
	testing.expect_value(t, usage_window_label(0), "limit")
	testing.expect_value(t, usage_clamp_percent(101), 100.0)
	testing.expect_value(t, usage_clamp_percent(-0.5), -1.0) // below 0: not a percent
	testing.expect_value(t, usage_level(79.9, false), Usage_Level.Normal)
	testing.expect_value(t, usage_level(80, false), Usage_Level.Warn)
	testing.expect_value(t, usage_level(94.9, false), Usage_Level.Warn)
	testing.expect_value(t, usage_level(95, false), Usage_Level.Full)
	testing.expect_value(t, usage_level(10, true), Usage_Level.Full)
	testing.expect_value(t, usage_age_text(0, UT_NOW), "")
	testing.expect_value(t, usage_age_text(UT_NOW - 30, UT_NOW), "now")
	testing.expect_value(t, usage_age_text(UT_NOW - 4 * 60, UT_NOW), "4m ago")
	testing.expect_value(t, usage_age_text(UT_NOW - 3 * 3600, UT_NOW), "3h ago")
	testing.expect_value(t, usage_age_text(UT_NOW + 50, UT_NOW), "now") // a clock that went back
	testing.expect(t, !usage_stale(UT_NOW - 59 * 60, UT_NOW))
	testing.expect(t, usage_stale(UT_NOW - 60 * 60, UT_NOW))
	testing.expect(t, !usage_stale(0, UT_NOW), "never read: not stale")
	w := Usage_Window{used_percent = 50, window_mins = 300, resets_at = UT_NOW - 10}
	testing.expect(t, usage_reset_passed(w, UT_NOW - 3600, UT_NOW), "read before the reset, which passed")
	testing.expect(t, !usage_reset_passed(w, UT_NOW - 5, UT_NOW), "read after the reset: it holds")
	w.resets_at = UT_NOW + 10
	testing.expect(t, !usage_reset_passed(w, UT_NOW - 3600, UT_NOW))
	testing.expect_value(t, usage_plan_name("plus"), "Plus")
	testing.expect_value(t, usage_plan_name("self_serve_business_prolite"), "Self serve business prolite")
}

@(test)
usage_rows_say_what_is_shown :: proc(t: ^testing.T) {
	e := Usage_Account{key = "codex:/h", home = "/h", label = "Work", status = .Ok, plan = "plus", credits = "none", read_at = UT_NOW - 4 * 60}
	ws := [?]Usage_Window{{used_percent = 82.4, window_mins = 300, resets_at = UT_NOW + 3600}, {used_percent = 96, window_mins = 10080, resets_at = UT_NOW + 86400}, {name = "Spark", used_percent = 3, window_mins = 300}}
	e.windows = ws[:]
	r := usage_row(e, UT_NOW)
	testing.expect_value(t, len(r.bars), 2) // the main limit's windows only
	testing.expect_value(t, r.bars[0].label, "5h")
	testing.expect_value(t, r.bars[0].percent, 82)
	testing.expect_value(t, r.bars[0].level, Usage_Level.Warn)
	testing.expect_value(t, r.bars[1].level, Usage_Level.Full)
	testing.expect_value(t, r.fullest, 1)
	testing.expect_value(t, r.line, "wk 96% · 4m ago")
	testing.expect_value(t, r.age, "4m ago")
	testing.expect(t, !r.stale)
	testing.expect(t, strings.has_prefix(r.bars[0].reset, "resets "))
	for want in ([]string{"Plus plan", "5h 82%", "wk 96%", "Spark 5h 3%", "credits: none", "from Codex app-server", "/h", "read 4m ago"}) do testing.expectf(t, strings.contains(r.tip, want), "tip %q lacks %q", r.tip, want)
	// a limit hit: the fullest window is red whatever its percent
	e.limit_hit = true
	ws[1].used_percent = 60
	r = usage_row(e, UT_NOW)
	testing.expect_value(t, r.fullest, 0)
	testing.expect_value(t, r.bars[0].level, Usage_Level.Full) // 82%, but the limit is hit
	testing.expect_value(t, r.bars[1].level, Usage_Level.Normal)
	e.limit_hit = false
	ws[1].used_percent = 96
	// an hour later: faded; the 5h window's reset passed: no percent, says so
	r = usage_row(e, UT_NOW + 2 * 3600)
	testing.expect(t, r.stale)
	testing.expect(t, r.bars[0].passed)
	testing.expect_value(t, r.bars[0].note, fmt.tprintf("reset at %s, no new data", usage_clock_text(UT_NOW + 3600, UT_NOW + 2 * 3600)))
	testing.expect_value(t, r.bars[0].level, Usage_Level.Normal)
	testing.expect_value(t, r.fullest, 1) // the window that still holds
	testing.expect(t, strings.contains(r.tip, "no new data"))
	// statuses with no bars say what they are
	notes := [?]struct {
		st:   Usage_Status,
		note: string,
	}{{.Unknown, "not read yet"}, {.No_Limits, "no plan limits (API key)"}, {.Signed_Out, "signed out"}, {.Error, "can't read: boom"}}
	for n in notes {
		x := Usage_Account{key = "codex:/h", home = "/h", label = "Work", status = n.st, error = "boom"}
		rr := usage_row(x, UT_NOW)
		testing.expect_value(t, len(rr.bars), 0)
		testing.expect_value(t, rr.note, n.note)
		testing.expect_value(t, rr.line, n.note) // folded: the same words
		testing.expect_value(t, rr.fullest, -1)
	}
}

@(test)
usage_keys_and_merge :: proc(t: ^testing.T) {
	a := ut_dir("acct-a")
	b := ut_dir("acct-b")
	def := ut_reset(a, b)
	defer ut_done()
	usage_tick()
	testing.expect_value(t, len(state.usage), 3)
	testing.expect_value(t, state.usage[0].key, usage_codex_key(def))
	testing.expect_value(t, state.usage[0].status, Usage_Status.Unknown)
	testing.expect_value(t, state.usage[1].key, fmt.tprintf("codex:%s", a))
	// a and b read the same account: one entry, the newer read's, naming the other home
	usage_apply_for_test(a, ut_ok(hash = "h1", p5 = 10))
	usage_test_now = UT_NOW + 60
	usage_apply_for_test(b, ut_ok(hash = "h1", p5 = 20))
	testing.expect_value(t, len(state.usage), 2)
	testing.expect_value(t, state.usage[1].home, a) // the first account's row
	testing.expect_value(t, state.usage[1].windows[0].used_percent, 20.0) // b's newer numbers
	testing.expect_value(t, len(state.usage[1].also), 1)
	testing.expect_value(t, state.usage[1].also[0], b)
	testing.expect(t, strings.contains(usage_tip(state.usage[1], usage_now()), "+"), "the hover names both homes")
	// another account: apart again
	usage_apply_for_test(a, ut_ok(hash = "h2"))
	testing.expect_value(t, len(state.usage), 3)
	// a failure after a good read keeps the numbers and says why
	usage_apply_for_test(a, Usage_Read{status = .Error, error = "codex app-server did not answer in time"})
	testing.expect_value(t, state.usage[1].status, Usage_Status.Ok)
	testing.expect_value(t, state.usage[1].windows[0].used_percent, 42.0)
	testing.expect_value(t, state.usage[1].error, "codex app-server did not answer in time")
	// signed out: the numbers go
	usage_apply_for_test(a, Usage_Read{status = .Signed_Out})
	testing.expect_value(t, state.usage[1].status, Usage_Status.Signed_Out)
	testing.expect_value(t, len(state.usage[1].windows), 0)
	// the snapshot never carries the hash
	b2 := strings.builder_make(context.temp_allocator)
	usage_snapshot_json(&b2, state.usage)
	testing.expect(t, !strings.contains(strings.to_string(b2), "h1"), "no account hash in get_state")
	// Codex not installed: no entries
	harness_found[.Codex] = .No
	usage_test_now += 1
	usage_tick()
	testing.expect_value(t, len(state.usage), 0)
}

@(test)
usage_saved_and_restored :: proc(t: ^testing.T) {
	a := ut_dir("acct-r")
	def := ut_reset(a)
	defer ut_done()
	usage_apply_for_test(def, ut_ok(hash = "hh"))
	usage_apply_for_test(a, Usage_Read{status = .No_Limits})
	b := strings.builder_make(context.temp_allocator)
	usage_json(&b)
	text := strings.to_string(b)
	for bad in ([]string{"fake-account", "acct-123"}) do testing.expect(t, !strings.contains(text, bad))
	want := fmt.tprint(state.usage[0].windows)
	// a restart: the records gone, then back from the file
	usage_reset_for_test()
	testing.expect_value(t, state.usage[0].status, Usage_Status.Unknown)
	v, err := jg.parse_string(text, .JSON, true, context.temp_allocator)
	testing.expect(t, err == nil)
	usage_restore(v)
	usage_publish_for_test()
	testing.expect_value(t, len(state.usage), 2)
	testing.expect_value(t, state.usage[0].status, Usage_Status.Ok)
	testing.expect_value(t, state.usage[0].plan, "plus")
	testing.expect_value(t, state.usage[0].read_at, UT_NOW)
	testing.expect_value(t, state.usage[0].account_hash, "hh")
	testing.expect_value(t, fmt.tprint(state.usage[0].windows), want)
	testing.expect_value(t, state.usage[1].status, Usage_Status.No_Limits)
	// shown with its age after a restart; the next read waits for the poll time from that read
	testing.expect_value(t, usage_row(state.usage[0], UT_NOW + 10 * 60).age, "10m ago")
	next, _ := usage_next_at_for_test(def)
	testing.expect_value(t, next, UT_NOW + USAGE_POLL_EVERY)
	// what a file may hold that is not one: skipped
	odd := `[{"key":"codex:rel","source":"codex","home":"rel","status":"ok"},{"key":"codex:/x","source":"codex","home":"/y","status":"ok"},{"key":"claude:/z","source":"claude","home":"/z","status":"ok"},{"key":"codex:/w","source":"codex","home":"/w","status":"error"},7,{"key":"codex:/v","source":"codex","home":"/v","status":"ok","windows":[{"used_percent":900,"window_mins":-4},"x"]}]`
	ov, _ := jg.parse_string(odd, .JSON, true, context.temp_allocator)
	usage_restore(ov)
	j := strings.builder_make(context.temp_allocator)
	usage_json(&j)
	testing.expect_value(t, strings.to_string(j), "[]") // /v read nothing (read_at 0): not saved again
	_ = json.Value{}
}

@(test)
usage_due_times :: proc(t: ^testing.T) {
	def := ut_reset()
	defer ut_done()
	usage_apply_for_test(def, ut_ok())
	// a Codex turn of the default account ended: due 30 s later, never closer than a minute after
	// the last try
	usage_codex_turn_ended("")
	next, _ := usage_next_at_for_test(def)
	testing.expect_value(t, next, UT_NOW + USAGE_MIN_GAP) // the read just now: not closer than the gap
	usage_apply_for_test(def, ut_ok()) // read again: due at the poll time
	usage_test_now = UT_NOW + 120
	usage_codex_turn_ended("")
	next, _ = usage_next_at_for_test(def)
	testing.expect_value(t, next, UT_NOW + 120 + USAGE_AFTER_STOP)
	usage_codex_turn_ended("/not/an/account") // none of its own: nothing
	// Refresh usage: every account forced; refused with no Codex
	r := run_command(Refresh_Usage{}, {kind = .Internal})
	testing.expect(t, r.ok, r.error)
	_, forced := usage_next_at_for_test(def)
	testing.expect(t, forced)
	harness_found[.Codex] = .No
	r = run_command(Refresh_Usage{}, {kind = .Internal})
	testing.expect(t, !r.ok)
	testing.expect(t, strings.contains(r.error, "not installed"), r.error)
}

@(test)
usage_requests_and_script :: proc(t: ^testing.T) {
	a := ut_dir("acct-s")
	def := ut_reset(a)
	defer ut_done()
	init, initialized, read := usage_codex_requests()
	testing.expect(t, strings.contains(init, `"name":"deckhand"`))
	testing.expect(t, strings.contains(read, `"method":"account/rateLimits/read"`))
	testing.expect(t, strings.contains(read, `"excludeResetCreditDetails":true`))
	testing.expect_value(t, initialized, `{"method":"initialized"}`)
	for line in ([]string{init, initialized, read}) do testing.expect(t, json_valid(line), line)
	os.set_env("DECKHAND_CODEX_CMD", `exec fake "$@"`)
	defer os.unset_env("DECKHAND_CODEX_CMD")
	s := usage_codex_script(a)
	defer delete(s)
	testing.expect(t, strings.has_prefix(s, "set -- app-server; DECKHAND_CODEX_ACCOUNT="), s)
	testing.expect(t, strings.contains(s, a))
	testing.expect(t, !strings.contains(s, "auth.json"))
	d := usage_codex_script(def) // the default: nothing set, the environment's CODEX_HOME as tabs get it
	defer delete(d)
	testing.expect(t, !strings.contains(d, "DECKHAND_CODEX_ACCOUNT="), d)
	testing.expect_value(t, usage_codex_script("/not/an/account"), "")
}

// One exchange with a stand-in app-server (a shell line that answers as Codex's does: noise and a
// notification first), and one that never answers the read (the timeout is too long for a unit
// test: it stops at its stdin's end instead).
@(test)
usage_exchange_with_a_stand_in :: proc(t: ^testing.T) {
	ut_reset()
	defer ut_done()
	os.set_env("SHELL", "/bin/sh")
	home := "/h/.codex"
	script := strings.concatenate({`read a; case "$a" in *'"initialize"'*) ;; *) exit 3;; esac; echo 'profile noise'; printf '%s\n' '{"id":1,"result":{"codexHome":"`, home, `"}}' '{"method":"account/rateLimits/updated","params":{}}'; read b; read c; case "$c" in *excludeResetCreditDetails*) ;; *) exit 4;; esac; printf '%s\n' '{"id":2,"result":{"rateLimits":{"planType":"plus","primary":{"usedPercent":61,"windowDurationMins":300}}}}'; cat >/dev/null`}, context.temp_allocator)
	r := usage_codex_read(script, home)
	defer usage_read_free(r)
	testing.expectf(t, r.status == .Ok, "status %v: %s", r.status, r.error)
	testing.expect_value(t, len(r.windows), 1)
	testing.expect_value(t, r.windows[0].used_percent, 61.0)
	// a server that ends without answering
	r2 := usage_codex_read(`read a; exit 0`, home)
	defer usage_read_free(r2)
	testing.expect_value(t, r2.status, Usage_Status.Error)
	testing.expect(t, strings.contains(r2.error, "ended"), r2.error)
}


// Review #1: automatic reads only while the section can be seen. The window's facts say so
// (usage_visible: the left column open on the Sessions tab, the USAGE section drawn unfolded;
// hidden: hidden, minimised or occluded); a due read waits while either says no.
@(test)
usage_reads_only_when_seen :: proc(t: ^testing.T) {
	def := ut_reset()
	defer ut_done()
	f := Window_Facts{usage_visible = true}
	usage_test_facts = &f
	defer usage_test_facts = nil
	usage_tick()
	next, _ := usage_next_at_for_test(def)
	testing.expect_value(t, next, UT_NOW + USAGE_POLL_EVERY) // seen: read (tried) now
	later := UT_NOW + USAGE_POLL_EVERY + 60
	usage_test_now = later
	cases := []Window_Facts{
		{usage_visible = true, hidden = true}, // hidden, minimised or occluded
		{usage_visible = false}, // the Files tab, the Attention view, the column closed, folded
	}
	for c in cases {
		f = c
		usage_tick()
		next, _ = usage_next_at_for_test(def)
		testing.expectf(t, next == UT_NOW + USAGE_POLL_EVERY, "%v: read while not seen (next %d)", c, next - UT_NOW)
	}
	// seen again: the read that was due
	f = {usage_visible = true}
	usage_tick()
	next, _ = usage_next_at_for_test(def)
	testing.expect_value(t, next, later + USAGE_POLL_EVERY)
	// no facts yet (an older window): nothing is read automatically
	usage_test_now = later + 2 * USAGE_POLL_EVERY
	usage_test_facts = nil
	usage_tick()
	next, _ = usage_next_at_for_test(def)
	testing.expect_value(t, next, later + USAGE_POLL_EVERY)
}

// Review #2: a percent Codex did not say (or said below 0) stays unknown (-1: "?"), never 0%.
@(test)
usage_unknown_percent_stays_unknown :: proc(t: ^testing.T) {
	def := ut_reset()
	defer ut_done()
	testing.expect_value(t, usage_clamp_percent(-1), -1.0)
	testing.expect_value(t, usage_clamp_percent(-3), -1.0)
	testing.expect_value(t, usage_clamp_percent(0), 0.0)
	testing.expect_value(t, usage_clamp_percent(150), 100.0)
	read := ut_ok(p5 = -1)
	usage_apply_for_test(def, read)
	testing.expect_value(t, len(state.usage), 1)
	testing.expect_value(t, state.usage[0].windows[0].used_percent, -1.0)
	row := usage_row(state.usage[0], UT_NOW)
	testing.expect_value(t, row.bars[0].percent, -1)
	testing.expect_value(t, row.bars[0].level, Usage_Level.Normal)
	testing.expect_value(t, row.fullest, 1) // the known one
	// saved and restored: still unknown, and a saved window without its percent too
	b := strings.builder_make(context.temp_allocator)
	usage_json(&b)
	text := strings.to_string(b)
	testing.expect(t, strings.contains(text, `"used_percent":-1.0`), text)
	saved := strings.concatenate({`[{"key":"codex:`, def, `","source":"codex","home":"`, def, `","status":"ok","read_at":`, fmt.tprint(UT_NOW - 60), `,"windows":[{"name":"","used_percent":-1,"window_mins":300},{"name":"","window_mins":10080}]}]`}, context.temp_allocator)
	v, err := jg.parse_string(saved, .JSON, true, context.temp_allocator)
	testing.expect(t, err == nil)
	usage_restore(v)
	usage_publish_for_test()
	testing.expect_value(t, len(state.usage), 1)
	testing.expect_value(t, len(state.usage[0].windows), 2)
	testing.expect_value(t, state.usage[0].windows[0].used_percent, -1.0)
	testing.expect_value(t, state.usage[0].windows[1].used_percent, -1.0)
	row = usage_row(state.usage[0], UT_NOW)
	testing.expect_value(t, row.line, "5h ? · 1m ago")
}

// Review #3: Refresh usage is the user's (it starts a process per account, with no backoff):
// never an agent's, a script's or a pi tab's.
@(test)
usage_refresh_is_the_users :: proc(t: ^testing.T) {
	testing.expect(t, caller_may({kind = .UI}, Refresh_Usage{}), "the user")
	testing.expect(t, caller_may({kind = .Internal}, Refresh_Usage{}), "Deckhand")
	for k in ([]Caller_Kind{.Control, .Script, .Panel, .App}) do testing.expectf(t, !caller_may({kind = k}, Refresh_Usage{}), "%v may refresh usage", k)
	testing.expect(t, !caller_may({kind = .Panel, claude = true}, Refresh_Usage{}), "a Claude tab")
}

// Review #4: account hashes use this install's own random salt (a 0600 file in the data dir, never
// workspace.json), not a fixed public one; the hash never goes over the state wire.
@(test)
usage_salt_per_install :: proc(t: ^testing.T) {
	d := ut_dir("salt")
	path := fmt.tprintf("%s/usage-salt", d)
	os.remove(path)
	a, ok := usage_salt_load_from(path)
	testing.expect(t, ok, "a salt made")
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil && len(data) == 32, "32 bytes saved")
	if fi, e := os.stat(path, context.temp_allocator); testing.expect(t, e == nil) do testing.expectf(t, transmute(u32)fi.mode & 0o777 == 0o600, "mode %o", transmute(u32)fi.mode & 0o777)
	b, ok2 := usage_salt_load_from(path)
	testing.expect(t, ok2 && a == b, "read back the same")
	zero: [32]u8
	testing.expect(t, a != zero, "random")
	h := usage_hash_with(a[:], "acct-1")
	testing.expect_value(t, len(h), 32)
	testing.expect_value(t, usage_hash_with(b[:], "acct-1"), h)
	// another install: another salt, another hash
	os.remove(path)
	c, _ := usage_salt_load_from(path)
	testing.expect(t, c != a, "a new salt")
	testing.expect(t, usage_hash_with(c[:], "acct-1") != h, "another install's hash differs")
	// the old fixed-salt hash is not what is made now
	sum: [sha2.DIGEST_SIZE_256]u8
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	old := "deckhand-usage-account:acct-1"
	sha2.update(&ctx, transmute([]u8)old)
	sha2.final(&ctx, sum[:])
	testing.expect(t, h != string(hex.encode(sum[:16], context.temp_allocator)), "not the fixed salt's")
	testing.expect_value(t, usage_hash_with(a[:], ""), "")
	// a salt file that is not 32 bytes: no salt (never a short one)
	_ = os.write_entire_file(path, transmute([]u8)string("short"))
	_, ok3 := usage_salt_load_from(path)
	testing.expect(t, !ok3, "a bad salt file refused")
	// the hash stays in the core
	sk := wire_skip("Usage_Account", "account_hash")
	testing.expect(t, sk != nil && sk.why == .Core_Only, "account_hash is Core_Only on the state wire")
}

// Review #5: a home other than the default needs initialize's codexHome to match; missing, an
// error or not JSON: the read fails (never another account's numbers).
@(test)
usage_home_must_be_confirmed :: proc(t: ^testing.T) {
	read := `{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300}}}}`
	{
		r := usage_codex_parse(`{"id":1,"result":{"userAgent":"codex"}}`, read, "/h/work")
		defer usage_read_free(r)
		testing.expect_value(t, r.status, Usage_Status.Error)
		testing.expect_value(t, r.error, "can't confirm which account Codex read")
	}
	{ // the default home: Codex's own default, nothing to confirm
		r := usage_codex_parse(`{"id":1,"result":{"userAgent":"codex"}}`, read, "/h/.codex", default_home = true)
		defer usage_read_free(r)
		testing.expect_value(t, r.status, Usage_Status.Ok)
	}
	for init in ([]string{`{"id":1,"error":{"code":-32600,"message":"bad init"}}`, `not json`, ``, `{"id":1,"result":7}`}) {
		for def in ([]bool{false, true}) {
			r := usage_codex_parse(init, read, "/h/work", default_home = def)
			defer usage_read_free(r)
			testing.expectf(t, r.status == .Error, "init %q (default %v): %v", init, def, r.status)
		}
	}
}

// Review #6: only Codex's own words for a signed-out or API-key account (its app-server's account
// processor, 0.169); anything else is an error that keeps the last good numbers.
@(test)
usage_signed_out_wording :: proc(t: ^testing.T) {
	err :: proc(msg: string) -> string {return strings.concatenate({`{"id":2,"error":{"code":-32600,"message":"`, msg, `"}}`}, context.temp_allocator)}
	Case :: struct {
		msg:  string,
		want: Usage_Status,
	}
	for c in ([]Case{
		{"codex account authentication required to read rate limits", .Signed_Out},
		{"chatgpt authentication required to read rate limits", .No_Limits},
		{"not logged in", .Error},
		{"please sign in again", .Error},
		{"failed to fetch codex rate limits: authentication required by proxy", .Error},
		{"codex account authentication required to read token usage", .Error},
	}) {
		r := usage_codex_parse(init_reply("/h"), err(c.msg), "/h")
		defer usage_read_free(r)
		testing.expectf(t, r.status == c.want, "%q: %v, want %v", c.msg, r.status, c.want)
	}
}

// Review polish: the rows say what colour alone would (a limit reached, a reset that passed
// before the read); two windows of no said length are told apart; an email in Codex's words
// never reaches State.
@(test)
usage_rows_polish :: proc(t: ^testing.T) {
	now := UT_NOW
	hit := Usage_Account{key = "codex:/h", home = "/h", label = "W", status = .Ok, limit_hit = true, read_at = now - 60, windows = []Usage_Window{{used_percent = 100, window_mins = 300, resets_at = now + 600}}}
	row := usage_row(hit, now)
	testing.expect_value(t, row.note, "limit reached")
	testing.expect(t, strings.has_prefix(row.line, "limit reached · "), row.line)
	old := Usage_Account{key = "codex:/h", home = "/h", status = .Ok, read_at = now - 60, windows = []Usage_Window{{used_percent = 50, window_mins = 300, resets_at = now - 120}}}
	row = usage_row(old, now)
	testing.expect_value(t, row.bars[0].reset, "reset passed")
	testing.expect(t, !row.bars[0].passed, "the read came after it: its percent holds")
	two := Usage_Account{key = "codex:/h", home = "/h", status = .Ok, read_at = now, windows = []Usage_Window{{used_percent = 10}, {used_percent = 20}}}
	row = usage_row(two, now)
	testing.expect_value(t, len(row.bars), 2)
	testing.expect(t, row.bars[0].label != row.bars[1].label, "two unnamed windows share a label")
	r := usage_codex_parse(init_reply("/h"), `{"id":2,"error":{"message":"failed to fetch codex rate limits: account jane.doe+x@example.co.uk is suspended"}}`, "/h")
	defer usage_read_free(r)
	testing.expect_value(t, r.status, Usage_Status.Error)
	testing.expect(t, !strings.contains(r.error, "@") && !strings.contains(r.error, "jane"), r.error)
	testing.expect(t, strings.contains(r.error, "suspended"), r.error)
}

// Review polish: saving drops an account that was removed; a saved read time in the future
// (a clock set back) comes back as now.
@(test)
usage_saving_polish :: proc(t: ^testing.T) {
	w := ut_dir("acct-w")
	def := ut_reset(w)
	defer ut_done()
	usage_apply_for_test(def, ut_ok())
	usage_apply_for_test(w, ut_ok())
	clear(&state.settings.codex_accounts)
	claude_accounts_gen += 1
	b := strings.builder_make(context.temp_allocator)
	usage_json(&b)
	text := strings.to_string(b)
	testing.expect(t, strings.contains(text, def), text)
	testing.expect(t, !strings.contains(text, w), "a removed account's read saved")
	saved := strings.concatenate({`[{"key":"codex:`, def, `","source":"codex","home":"`, def, `","status":"ok","read_at":`, fmt.tprint(UT_NOW + 86400), `,"windows":[]}]`}, context.temp_allocator)
	v, _ := jg.parse_string(saved, .JSON, true, context.temp_allocator)
	usage_restore(v)
	usage_publish_for_test()
	testing.expect_value(t, len(state.usage), 1)
	testing.expect_value(t, state.usage[0].read_at, UT_NOW)
}

// Review polish: the 256 KB is the whole run's output (a server that floods lines it never
// answers with is stopped at once, not when it ends or times out).
@(test)
usage_output_cap :: proc(t: ^testing.T) {
	ut_reset()
	defer ut_done()
	os.set_env("SHELL", "/bin/sh")
	flood := `read a; i=0; while [ $i -lt 6000 ]; do echo '{"method":"noise","params":{"pad":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}}'; i=$((i+1)); done; exit 0`
	r := usage_codex_read(flood, "/h", default_home = true)
	defer usage_read_free(r)
	testing.expect_value(t, r.status, Usage_Status.Error)
	testing.expect(t, strings.contains(r.error, "too long"), r.error)
}

} // when TEST_HOOKS
