package core

// Claude Code's usage (usage_claude.odin): claude.usage's numbers checked (clamped, unknown as -1)
// and only from the tab's own plugin, the live and background numbers merged, the background read
// held off while a tab's status line is fresher, the two switches, get_usage's answers parsed
// loosely (Claude Code 2.1.332's SDKControlGetUsageResponse), the user's status line found and the
// tab's --settings built or merged, and one exchange with a stand-in claude (a shell line: never a
// real claude).

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

when TEST_HOOKS {

@(private = "file")
UC_NOW :: i64(1_795_000_000)

@(private = "file")
uc_dir :: proc(name: string) -> string {
	d := fmt.tprintf("%s/uc-%s", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), name)
	os.remove_all(d)
	os.make_directory_all(d)
	return d
}

// A fresh setup: a fake HOME with ~/.claude (the default account), Claude Code "installed" and
// Codex not, both switches on, no records, no managed settings. Returns the default config folder.
@(private = "file")
uc_reset :: proc() -> string {
	home := uc_dir("home")
	os.set_env("HOME", home)
	os.unset_env("CLAUDE_CONFIG_DIR")
	os.set_env("DECKHAND_CLAUDE_MANAGED_DIR", "") // never this Mac's own
	cfg := fmt.tprintf("%s/.claude", home)
	os.make_directory_all(cfg)
	harness_found[.Claude] = .Yes
	harness_found[.Codex] = .No
	clear(&state.settings.claude_accounts)
	state.settings.claude_usage_statusline_off = false
	state.settings.claude_usage_background_off = false
	claude_accounts_gen += 1
	usage_test_now = UC_NOW
	usage_reset_for_test()
	return claude_account_dir("", .Claude)
}

@(private = "file")
uc_done :: proc() {
	harness_found[.Claude] = .Unknown
	harness_found[.Codex] = .Unknown
	state.settings.claude_usage_statusline_off = false
	state.settings.claude_usage_background_off = false
	os.unset_env("DECKHAND_CLAUDE_MANAGED_DIR")
	claude_accounts_gen += 1
	usage_reset_for_test()
	usage_test_now = 0
}

@(private = "file")
uc_write :: proc(path, text: string) {
	os.make_directory_all(path[:strings.last_index_byte(path, '/')])
	_ = os.write_entire_file(path, transmute([]u8)text)
}

@(private = "file")
uc_entry :: proc(key: string) -> ^Usage_Account {
	for &e in state.usage do if e.key == key do return &e
	return nil
}

// claude.usage's numbers: a percent clamped to 0..100, below 0 unknown (-1), a reset time only
// between 0 and the year 3000, a window with neither left out; spend in dollars when both are
// there, else its percent.
@(test)
usage_claude_report_checked :: proc(t: ^testing.T) {
	l := usage_claude_live_of({five_hour = 150, five_hour_resets = UC_NOW + 3600, seven_day = -4, seven_day_resets = 99_999_999_999, spend = -1, spend_used_usd = -1, spend_limit_usd = -1})
	testing.expect_value(t, l.n, 1) // 7d: unknown and no reset: left out
	testing.expect_value(t, l.windows[0].used_percent, 100.0)
	testing.expect_value(t, l.windows[0].window_mins, i64(300))
	testing.expect_value(t, l.windows[0].resets_at, UC_NOW + 3600)
	testing.expect_value(t, l.spend, "")
	l = usage_claude_live_of({five_hour = -1, five_hour_resets = UC_NOW + 60, seven_day = 12.4, spend = 30, spend_used_usd = 12.5, spend_limit_usd = 50})
	testing.expect_value(t, l.n, 2)
	testing.expect_value(t, l.windows[0].used_percent, -1.0) // its reset is known: kept, "?"
	testing.expect_value(t, l.windows[1].used_percent, 12.4)
	testing.expect_value(t, l.windows[1].window_mins, i64(7 * 24 * 60))
	testing.expect_value(t, l.spend, "spend $12.50 of $50.00")
	l = usage_claude_live_of({five_hour = -1, seven_day = -1, spend = 250, spend_used_usd = -1, spend_limit_usd = 0})
	testing.expect_value(t, l.n, 0)
	testing.expect_value(t, l.spend, "spend 100%")
	// the codec: a field left out is -1 (not said), never 0%
	cmd, err := parse_command(`{"type":"claude.usage","five_hour":42}`)
	testing.expect_value(t, err, "")
	c, is := cmd.(Claude_Usage_Report)
	testing.expect(t, is)
	testing.expect_value(t, c.five_hour, 42.0)
	testing.expect_value(t, c.seven_day, -1.0)
	testing.expect_value(t, c.spend, -1.0)
	testing.expect_value(t, c.five_hour_resets, i64(0))
}

// Only a Claude tab's own plugin reports for that tab: not another tab's, a pi bridge, a control
// token or an app.
@(test)
usage_claude_report_is_the_tabs_own :: proc(t: ^testing.T) {
	r := Claude_Usage_Report{tab_id = 7, five_hour = 10}
	testing.expect(t, caller_may({kind = .Panel, claude = true, tab_id = 7}, r), "its own tab")
	testing.expect(t, !caller_may({kind = .Panel, claude = true, tab_id = 8}, r), "another Claude tab")
	testing.expect(t, !caller_may({kind = .Panel, claude = false, tab_id = 7}, r), "a pi bridge")
	for k in ([]Caller_Kind{.Control, .App, .UI}) do testing.expectf(t, !caller_may({kind = k}, r), "%v may report usage", k)
	// a tab that is no Claude tab (or none): refused when run
	ur, _ := usage_claude_report_apply(Claude_Usage_Report{tab_id = 999_999})
	testing.expect(t, !ur.ok)
	testing.expect_value(t, ur.error, "no such Claude tab")
	// the switches are the user's at this Mac
	testing.expect(t, caller_may({kind = .UI}, Set_Claude_Usage{statusline = false}))
	for k in ([]Caller_Kind{.Control, .Script, .Panel}) do testing.expectf(t, !caller_may({kind = k}, Set_Claude_Usage{background = false}), "%v may set the usage switches", k)
}

// Live numbers and a background read merge: the background read's model windows join the live
// main windows; live numbers that came while the read ran are kept over its main windows; an older
// live read gives way to it. The same live numbers again within USAGE_LIVE_SAME change nothing.
@(test)
usage_claude_live_and_background :: proc(t: ^testing.T) {
	def := uc_reset()
	defer uc_done()
	key := usage_claude_key(def)
	usage_publish_for_test()
	testing.expect_value(t, len(state.usage), 1)
	testing.expect_value(t, state.usage[0].key, key)
	testing.expect_value(t, state.usage[0].status, Usage_Status.Unknown)
	usage_claude_live(def, "", usage_claude_live_of({five_hour = 40, five_hour_resets = UC_NOW + 3600, seven_day = 10, seven_day_resets = UC_NOW + 86400, spend = -1, spend_used_usd = -1, spend_limit_usd = -1}))
	usage_publish_for_test()
	e := uc_entry(key)
	testing.expect(t, e != nil)
	testing.expect_value(t, e.status, Usage_Status.Ok)
	testing.expect_value(t, e.via, Usage_Via.Status_Line)
	testing.expect_value(t, len(e.windows), 2)
	testing.expect(t, strings.contains(usage_tip(e^, UC_NOW), "from Claude status line"), usage_tip(e^, UC_NOW))
	// a background read that began before those numbers came: its model windows join, its main
	// windows do not replace them
	bg := Usage_Read{status = .Ok, plan = "max", windows = make([dynamic]Usage_Window, context.temp_allocator)}
	append(&bg.windows, Usage_Window{used_percent = 50, window_mins = 300}, Usage_Window{used_percent = 20, window_mins = 10080}, Usage_Window{name = "Opus", used_percent = 30, window_mins = 10080})
	usage_apply_for_test_at(def, bg, UC_NOW - 5)
	e = uc_entry(key)
	testing.expect_value(t, e.via, Usage_Via.Status_Line)
	testing.expect_value(t, len(e.windows), 3)
	testing.expect_value(t, e.windows[0].used_percent, 40.0)
	testing.expect_value(t, e.windows[2].name, "Opus")
	testing.expect_value(t, e.plan, "max")
	testing.expect_value(t, e.extra_at, UC_NOW)
	// later live numbers keep the model windows
	usage_test_now = UC_NOW + 60
	usage_claude_live(def, "", usage_claude_live_of({five_hour = 45, seven_day = 11, spend = -1, spend_used_usd = -1, spend_limit_usd = -1}))
	usage_publish_for_test()
	e = uc_entry(key)
	testing.expect_value(t, len(e.windows), 3)
	testing.expect_value(t, e.windows[0].used_percent, 45.0)
	testing.expect_value(t, e.windows[2].name, "Opus")
	testing.expect(t, strings.contains(usage_tip(e^, UC_NOW + 60), "model limits: background check"), usage_tip(e^, UC_NOW + 60))
	// the same again soon after: nothing changes (its read time either)
	usage_test_now = UC_NOW + 70
	usage_claude_live(def, "", usage_claude_live_of({five_hour = 45, seven_day = 11, spend = -1, spend_used_usd = -1, spend_limit_usd = -1}))
	usage_publish_for_test()
	testing.expect_value(t, uc_entry(key).read_at, UC_NOW + 60)
	// a background read that began after the last live numbers: its main windows win
	usage_test_now = UC_NOW + 1000
	bg2 := Usage_Read{status = .Ok, windows = make([dynamic]Usage_Window, context.temp_allocator)}
	append(&bg2.windows, Usage_Window{used_percent = 70, window_mins = 300})
	usage_apply_for_test(def, bg2, .Claude)
	e = uc_entry(key)
	testing.expect_value(t, e.via, Usage_Via.Background)
	testing.expect_value(t, len(e.windows), 1)
	testing.expect_value(t, e.windows[0].used_percent, 70.0)
	testing.expect(t, strings.contains(usage_tip(e^, UC_NOW + 1000), "from background check"))
	// a full main window is a limit reached
	usage_claude_live(def, "", usage_claude_live_of({five_hour = 100, seven_day = 11, spend = -1, spend_used_usd = -1, spend_limit_usd = -1}))
	usage_publish_for_test()
	testing.expect(t, uc_entry(key).limit_hit)
	// saved and restored: its way and the model windows' time come back
	b := strings.builder_make(context.temp_allocator)
	usage_json(&b)
	text := strings.to_string(b)
	testing.expect(t, strings.contains(text, `"source":"claude"`), text)
	testing.expect(t, strings.contains(text, `"via":"status_line"`), text)
}

// The background read waits while a tab's status line gave numbers newer than USAGE_POLL_EVERY;
// once they age it is due. Refresh usage reads at once.
@(test)
usage_claude_background_waits_for_stale_live :: proc(t: ^testing.T) {
	def := uc_reset()
	defer uc_done()
	f := Window_Facts{usage_visible = true}
	usage_test_facts = &f
	defer usage_test_facts = nil
	usage_claude_live(def, "", usage_claude_live_of({five_hour = 40, seven_day = 10, spend = -1, spend_used_usd = -1, spend_limit_usd = -1}))
	usage_test_now = UC_NOW + 60
	usage_tick()
	next, _ := usage_next_at_for_test(def, .Claude)
	testing.expect_value(t, next, UC_NOW + USAGE_POLL_EVERY) // not tried: due once the live numbers age
	usage_test_now = UC_NOW + USAGE_POLL_EVERY + 1
	usage_tick()
	next, _ = usage_next_at_for_test(def, .Claude)
	testing.expect_value(t, next, UC_NOW + 2 * USAGE_POLL_EVERY + 1) // tried now (unit tests run nothing)
	// fresh live numbers again; Refresh usage still reads now
	usage_claude_live(def, "", usage_claude_live_of({five_hour = 41, seven_day = 10, spend = -1, spend_used_usd = -1, spend_limit_usd = -1}))
	r := run_command(Refresh_Usage{}, {kind = .UI})
	testing.expect(t, r.ok, r.error)
	_, forced := usage_next_at_for_test(def, .Claude)
	testing.expect(t, forced)
	usage_tick()
	_, forced = usage_next_at_for_test(def, .Claude)
	testing.expect(t, !forced)
}

// The switches: background off, no background read (Refresh usage says why); status line off, a
// report changes nothing and new tabs are not wrapped; both off, no Claude rows. Saved only when
// off (on by default).
@(test)
usage_claude_switches :: proc(t: ^testing.T) {
	def := uc_reset()
	defer uc_done()
	f := Window_Facts{usage_visible = true}
	usage_test_facts = &f
	defer usage_test_facts = nil
	run_command(Set_Claude_Usage{background = false}, {kind = .UI})
	testing.expect(t, state.settings.claude_usage_background_off)
	usage_tick()
	next, _ := usage_next_at_for_test(def, .Claude)
	testing.expect_value(t, next, i64(0)) // never tried
	r := run_command(Refresh_Usage{}, {kind = .UI})
	testing.expect(t, !r.ok)
	testing.expect(t, strings.contains(r.error, "in the background is off"), r.error)
	usage_publish_for_test()
	testing.expect_value(t, len(state.usage), 1) // the live way is on: its row stays
	// the status line off: not wrapped, and a report does not change the row
	run_command(Set_Claude_Usage{statusline = false}, {kind = .UI})
	insert, _, wrap := usage_claude_inject(nil, "/x/deckhand-cli", def, "")
	testing.expect_value(t, wrap, Usage_Wrap.Off)
	testing.expect_value(t, len(insert), 0)
	usage_publish_for_test()
	testing.expect_value(t, len(state.usage), 0) // both off: no Claude rows
	// saved when off, and back
	text := workspace_json()
	testing.expect(t, strings.contains(text, `"claude_usage_statusline":false`), text)
	testing.expect(t, strings.contains(text, `"claude_usage_background":false`), text)
	run_command(Set_Claude_Usage{statusline = true, background = true}, {kind = .UI})
	testing.expect(t, !state.settings.claude_usage_statusline_off && !state.settings.claude_usage_background_off)
	text2 := workspace_json()
	testing.expect(t, !strings.contains(text2, "claude_usage_"), text2)
}

// get_usage's answers, read loosely: a subscriber's windows (5h, 7d, then the model ones), a
// percent unknown or out of range, extra usage; no plan limits for an API key, Bedrock or Vertex;
// signed out; an error answer; answers that are not JSON.
@(test)
usage_claude_parse_answers :: proc(t: ^testing.T) {
	init := `{"type":"control_response","response":{"subtype":"success","request_id":"deckhand-usage-1","response":{"commands":[],"account":{"email":"someone@example.com","subscriptionType":"max","apiProvider":"firstParty"}}}}`
	full := `{"type":"control_response","response":{"subtype":"success","request_id":"deckhand-usage-2","response":{"session":{"total_cost_usd":0},"subscription_type":"max","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":42.5,"resets_at":"2026-11-27T20:00:00Z"},"seven_day":{"utilization":118,"resets_at":"2026-12-01T09:00:00+00:00"},"seven_day_opus":{"utilization":null,"resets_at":null},"seven_day_sonnet":{"utilization":7,"resets_at":null},"model_scoped":[{"display_name":"Fable","utilization":3,"resets_at":"2026-12-01T09:00:00Z"},{"utilization":9}],"extra_usage":{"is_enabled":true,"monthly_limit":50,"used_credits":12.5,"utilization":null},"future_field":{"x":1}},"behaviors":null}}}`
	r := usage_claude_parse(init, full)
	defer usage_read_free(r)
	testing.expectf(t, r.status == .Ok, "%v %s", r.status, r.error)
	testing.expect_value(t, r.plan, "max")
	testing.expect_value(t, len(r.windows), 4) // 5h, 7d, Sonnet, Fable (Opus: nothing said)
	testing.expect_value(t, r.windows[0].used_percent, 42.5)
	testing.expect_value(t, r.windows[0].window_mins, i64(300))
	testing.expect_value(t, r.windows[0].resets_at, usage_iso_time("2026-11-27T20:00:00Z"))
	testing.expect(t, r.windows[0].resets_at > 0)
	testing.expect_value(t, r.windows[1].used_percent, 100.0)
	testing.expect(t, r.limit_hit)
	testing.expect_value(t, r.windows[2].name, "Sonnet")
	testing.expect_value(t, r.windows[2].resets_at, i64(0))
	testing.expect_value(t, r.windows[3].name, "Fable")
	testing.expect_value(t, r.credits, "extra usage 25% of its monthly limit")
	testing.expect(t, !strings.contains(r.credits, "@"))
	none := `{"type":"control_response","response":{"subtype":"success","request_id":"deckhand-usage-2","response":{"subscription_type":null,"rate_limits_available":false,"rate_limits":null,"behaviors":null}}}`
	acct :: proc(fields: string) -> string {return fmt.tprintf(`{{"type":"control_response","response":{{"subtype":"success","request_id":"deckhand-usage-1","response":{{"account":{{%s}}}}}}}}`, fields)}
	cases := []struct {
		init:   string,
		status: Usage_Status,
		why:    string,
	}{
		{acct(`"apiKeySource":"ANTHROPIC_API_KEY","apiProvider":"firstParty"`), .No_Limits, ""},
		{acct(`"apiProvider":"bedrock"`), .No_Limits, "Bedrock"},
		{acct(`"apiProvider":"vertex"`), .No_Limits, "Vertex"},
		{acct(`"apiProvider":"firstParty"`), .Signed_Out, ""},
		{acct(``), .Signed_Out, ""},
		{acct(`"subscriptionType":"pro"`), .Error, ""},
	}
	for c in cases {
		x := usage_claude_parse(c.init, none)
		testing.expectf(t, x.status == c.status, "%s: %v, want %v", c.init, x.status, c.status)
		testing.expect_value(t, x.no_limits_why, c.why)
		usage_read_free(x)
	}
	row := usage_row({key = "claude:/x", source = .Claude, home = "/x", status = .No_Limits, no_limits_why = "Bedrock"}, UC_NOW)
	testing.expect_value(t, row.note, "no plan limits (Bedrock)")
	row = usage_row({key = "claude:/x", source = .Claude, home = "/x", status = .No_Limits}, UC_NOW)
	testing.expect_value(t, row.note, "no plan limits (API key)")
	// an error answer, its words kept without an address; answers that are not JSON
	e := usage_claude_parse(init, `{"type":"control_response","response":{"subtype":"error","request_id":"deckhand-usage-2","error":"OAuth token for someone@example.com has expired"}}`)
	testing.expect_value(t, e.status, Usage_Status.Error)
	testing.expect(t, !strings.contains(e.error, "@") && strings.contains(e.error, "expired"), e.error)
	usage_read_free(e)
	for bad in ([][2]string{{"not json", full}, {init, "{"}, {`{"type":"control_response","response":{"subtype":"error","request_id":"deckhand-usage-1","error":"nope"}}`, full}}) {
		x := usage_claude_parse(bad[0], bad[1])
		testing.expect_value(t, x.status, Usage_Status.Error)
		usage_read_free(x)
	}
}

// The user's own status line: local, then project, then the account's user settings, the first
// that sets one; Deckhand's own (copied there) is not run again.
@(test)
usage_claude_user_statusline_order :: proc(t: ^testing.T) {
	def := uc_reset()
	defer uc_done()
	proj := uc_dir("proj")
	_, ok := usage_claude_user_statusline(def, proj)
	testing.expect(t, !ok)
	uc_write(fmt.tprintf("%s/settings.json", def), `{"statusLine":{"type":"command","command":"~/bin/user-line","padding":2,"refreshInterval":5}}`)
	sl, sok := usage_claude_user_statusline(def, proj)
	testing.expect(t, sok)
	testing.expect_value(t, sl.command, "~/bin/user-line")
	testing.expect_value(t, sl.padding.? or_else -9, 2.0)
	uc_write(fmt.tprintf("%s/.claude/settings.json", proj), `{"statusLine":{"type":"command","command":"project-line"}}`)
	sl, _ = usage_claude_user_statusline(def, proj)
	testing.expect_value(t, sl.command, "project-line")
	uc_write(fmt.tprintf("%s/.claude/settings.local.json", proj), `{"statusLine":{"type":"command","command":"local-line"}}`)
	sl, _ = usage_claude_user_statusline(def, proj)
	testing.expect_value(t, sl.command, "local-line")
	// not a command, or Deckhand's own: none
	uc_write(fmt.tprintf("%s/.claude/settings.local.json", proj), `{"statusLine":{"type":"static","command":"x"}}`)
	_, ok = usage_claude_user_statusline(def, proj)
	testing.expect(t, !ok)
	uc_write(fmt.tprintf("%s/.claude/settings.local.json", proj), `{"statusLine":{"type":"command","command":"'/Applications/Deckhand.app/Contents/MacOS/deckhand-cli' statusline"}}`)
	_, ok = usage_claude_user_statusline(def, proj)
	testing.expect(t, !ok)
	// a file that is not JSON is skipped
	uc_write(fmt.tprintf("%s/.claude/settings.local.json", proj), `{not json`)
	sl, _ = usage_claude_user_statusline(def, proj)
	testing.expect_value(t, sl.command, "project-line")
}

// The tab's --settings: added after --plugin-dir with the user's padding and refreshInterval; merged
// into the user's own inline --settings (either form); left alone (and said) for a file, a
// statusLine of theirs, disableAllHooks or managed settings that set a status line.
@(test)
usage_claude_settings_injected :: proc(t: ^testing.T) {
	def := uc_reset()
	defer uc_done()
	proj := uc_dir("proj2")
	cli := "/Apps/Deck hand/deckhand-cli"
	insert, args, wrap := usage_claude_inject({"--model", "opus"}, cli, def, proj)
	testing.expect_value(t, wrap, Usage_Wrap.Wrapped)
	testing.expect_value(t, len(insert), 2)
	testing.expect_value(t, insert[0], "--settings")
	testing.expect_value(t, insert[1], `{"statusLine":{"type":"command","command":"'/Apps/Deck hand/deckhand-cli' statusline"}}`)
	testing.expect_value(t, len(args), 2)
	testing.expect(t, json_valid(insert[1]))
	// the user's padding, refreshInterval and hideVimModeIndicator are kept
	uc_write(fmt.tprintf("%s/settings.json", def), `{"statusLine":{"type":"command","command":"x","padding":0,"refreshInterval":10,"hideVimModeIndicator":true}}`)
	insert, _, _ = usage_claude_inject(nil, cli, def, proj)
	testing.expect(t, strings.has_suffix(insert[1], `statusline","padding":0,"refreshInterval":10,"hideVimModeIndicator":true}}`), insert[1])
	// merged into theirs
	_, args, wrap = usage_claude_inject({"--settings", ` {"model":"opus","env":{"A":"1"}} `, "-c2"}, cli, def, proj)
	testing.expect_value(t, wrap, Usage_Wrap.Wrapped)
	testing.expect(t, strings.has_prefix(args[1], `{"model":"opus","env":{"A":"1"},"statusLine":{"type":"command"`), args[1])
	testing.expect(t, json_valid(args[1]), args[1])
	testing.expect_value(t, args[2], "-c2")
	_, args, wrap = usage_claude_inject({"--settings={}"}, cli, def, proj)
	testing.expect_value(t, wrap, Usage_Wrap.Wrapped)
	testing.expect(t, strings.has_prefix(args[0], `--settings={"statusLine":`), args[0])
	testing.expect(t, json_valid(args[0][len("--settings="):]), args[0])
	// left alone
	for given in ([][]string{{"--settings", "/x/my-settings.json"}, {"--settings", `{"statusLine":{"type":"command","command":"mine"}}`}, {"--settings", `{"broken"`}}) {
		ins, a, w := usage_claude_inject(given, cli, def, proj)
		testing.expectf(t, w == .Own_Settings && len(ins) == 0 && a[1] == given[1], "%v: %v", given, w)
	}
	_, _, wrap = usage_claude_inject({"--settings", `{"disableAllHooks":true}`}, cli, def, proj)
	testing.expect_value(t, wrap, Usage_Wrap.Hooks_Off)
	uc_write(fmt.tprintf("%s/.claude/settings.json", proj), `{"disableAllHooks":true}`)
	_, _, wrap = usage_claude_inject(nil, cli, def, proj)
	testing.expect_value(t, wrap, Usage_Wrap.Hooks_Off)
	uc_write(fmt.tprintf("%s/.claude/settings.local.json", proj), `{"disableAllHooks":false}`) // the local file says last
	_, _, wrap = usage_claude_inject(nil, cli, def, proj)
	testing.expect_value(t, wrap, Usage_Wrap.Wrapped)
	_, _, wrap = usage_claude_inject(nil, "", def, proj)
	testing.expect_value(t, wrap, Usage_Wrap.No_Cli)
	// managed settings with a status line, or managed hooks only: they win
	managed := uc_dir("managed")
	os.set_env("DECKHAND_CLAUDE_MANAGED_DIR", managed)
	uc_write(fmt.tprintf("%s/managed-settings.d/10-line.json", managed), `{"statusLine":{"type":"command","command":"corp"}}`)
	_, _, wrap = usage_claude_inject(nil, cli, def, proj)
	testing.expect_value(t, wrap, Usage_Wrap.Managed)
	os.remove(fmt.tprintf("%s/managed-settings.d/10-line.json", managed))
	uc_write(fmt.tprintf("%s/managed-settings.json", managed), `{"allowManagedHooksOnly":true}`)
	_, _, wrap = usage_claude_inject(nil, cli, def, proj)
	testing.expect_value(t, wrap, Usage_Wrap.Managed)
	// the row says why a running tab sends nothing
	usage_claude_tab_started(41, def, proj, .Managed)
	testing.expect_value(t, usage_claude_live_note(def), "managed status line: no live numbers from its tabs")
	usage_claude_tab_started(41, def, proj, .Hooks_Off)
	testing.expect(t, strings.contains(usage_claude_live_note(def), "disableAllHooks"))
	usage_claude_tab_started(41, def, proj, .Wrapped)
	testing.expect_value(t, usage_claude_live_note(def), "")
}

// The background read's script and requests: print mode with stream-json, no session saved, no
// hooks or MCP servers of the user's; the account set after the login profile; never a prompt.
@(test)
usage_claude_script_and_requests :: proc(t: ^testing.T) {
	def := uc_reset()
	defer uc_done()
	init, read := usage_claude_requests()
	testing.expect(t, json_valid(init) && json_valid(read))
	testing.expect(t, strings.contains(read, `"subtype":"get_usage","skip_behaviors":true`), read)
	other := uc_dir("acct-c")
	append(&state.settings.claude_accounts, Claude_Account_Setting{dir = strings.clone(other, runtime.heap_allocator()), added = true})
	claude_accounts_gen += 1
	os.set_env("DECKHAND_CLAUDE_CMD", `exec fake "$@"`)
	defer os.unset_env("DECKHAND_CLAUDE_CMD")
	s := usage_claude_script(other)
	defer delete(s)
	for want in ([]string{"'--print'", "'--input-format' 'stream-json'", "'--output-format' 'stream-json'", "'--verbose'", "'--no-session-persistence'", `'{"disableAllHooks":true}'`, "'--strict-mcp-config'", "ENABLE_CLAUDEAI_MCP_SERVERS=false", "DECKHAND_CLAUDE_ACCOUNT=", other, `exec fake "$@"`}) do testing.expectf(t, strings.contains(s, want), "%q not in %s", want, s)
	testing.expect(t, !strings.contains(s, ".credentials.json") && !strings.contains(s, ".claude.json"))
	d := usage_claude_script(def) // the default: nothing set
	defer delete(d)
	testing.expect(t, !strings.contains(d, "DECKHAND_CLAUDE_ACCOUNT="), d)
	testing.expect_value(t, usage_claude_script("/not/an/account"), "")
	clear(&state.settings.claude_accounts)
}

// One exchange with a stand-in claude (a shell line answering as Claude Code's control protocol
// does: noise, a system message, then the answers), and one that ends without answering.
@(test)
usage_claude_exchange_with_a_stand_in :: proc(t: ^testing.T) {
	uc_reset()
	defer uc_done()
	os.set_env("SHELL", "/bin/sh")
	script := `read a; case "$a" in *'"subtype":"initialize"'*) ;; *) exit 3;; esac; echo 'profile noise'; printf '%s\n' '{"type":"system","subtype":"x"}' '{"type":"control_response","response":{"subtype":"success","request_id":"deckhand-usage-1","response":{"account":{"subscriptionType":"pro"}}}}'; read b; case "$b" in *get_usage*skip_behaviors*) ;; *) exit 4;; esac; printf '%s\n' '{"type":"control_response","response":{"subtype":"success","request_id":"deckhand-usage-2","response":{"subscription_type":"pro","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":61,"resets_at":null}}}}}'; cat >/dev/null`
	r := usage_claude_read(script)
	defer usage_read_free(r)
	testing.expectf(t, r.status == .Ok, "status %v: %s", r.status, r.error)
	testing.expect_value(t, len(r.windows), 1)
	testing.expect_value(t, r.windows[0].used_percent, 61.0)
	testing.expect_value(t, r.plan, "pro")
	r2 := usage_claude_read(`read a; exit 0`)
	defer usage_read_free(r2)
	testing.expect_value(t, r2.status, Usage_Status.Error)
	testing.expect(t, strings.contains(r2.error, "ended"), r2.error)
}

}
