package core

// Claude Code's usage (usage.odin; docs/CLAUDE-TABS.md §6c): its plan limits (the 5-hour and
// weekly windows, per-model weekly ones, extra usage), from two places, each with its own switch
// (Settings › Coding agents › Claude Code; both on by default):
//
//   - Live, from Claude tabs: the status line. Claude Code hands its status line command a JSON
//     object on stdin that has `rate_limits` (five_hour and seven_day: used_percentage, resets_at
//     in Unix seconds; a gateway's spend_limit) for a subscriber once an API answer came. A
//     plugin cannot set a status line, so a Claude tab starts with `--settings
//     '{"statusLine":{…}}'` naming `deckhand statusline` (the CLI; usage_claude_inject), which
//     sends only those numbers here (claude.usage, the tab's own) and runs the user's own status
//     line, which this answers with (usage_claude_user_statusline). Starts nothing.
//   - In the background: a headless claude with the account's CLAUDE_CONFIG_DIR, spoken to in the
//     Agent SDK's control protocol (stream-json over stdio): `initialize`, then `get_usage` with
//     skip_behaviors (its answer: rate_limits_available and rate_limits, from the claude.ai usage
//     endpoint Claude Code itself calls), then stdin closed. No prompt is ever sent, so no model
//     is asked. Under usage.odin's rules: only while the section is seen, every USAGE_POLL_EVERY
//     but not while a tab's status line gave newer numbers, Refresh usage; one at a time.
//
// Deckhand never reads .credentials.json, .claude.json or the Keychain and never calls an
// Anthropic endpoint: claude does, with its own sign-in. Only settings files are read here
// (settings.json, .claude/settings.json, .claude/settings.local.json, managed-settings.json),
// for their statusLine, disableAllHooks and allowManagedHooksOnly. There is no account id kept:
// two config folders are two rows, whatever account they hold.
//
// Test mode runs DECKHAND_CLAUDE_CMD (tests/scripts/fake-claude.py, which answers get_usage and
// runs the status line), never a real claude; unit tests start nothing unless one asks.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sys/posix"
import "core:time"
import jg "../jsonguard"

// ---- the switches (Settings › Coding agents › Claude Code) ----

// Show Claude usage (wraps your status line): the tabs started from now on get the status line.
usage_claude_statusline_on :: proc() -> bool {return !state.settings.claude_usage_statusline_off}
// Check Claude usage in the background (starts claude briefly).
usage_claude_background_on :: proc() -> bool {return !state.settings.claude_usage_background_off}
// Claude Code's accounts have rows: it is installed and one of the two is on.
usage_claude_on :: proc() -> bool {return (usage_claude_statusline_on() || usage_claude_background_on()) && claude_installed()}

// Settings' two switches (the user's, at this Mac). A field left out stays as it is.
Set_Claude_Usage :: struct {
	statusline: Maybe(bool), // Show Claude usage (wraps your status line)
	background: Maybe(bool), // Check Claude usage in the background (starts claude briefly)
}

usage_claude_set :: proc(c: Set_Claude_Usage) -> (Result, bool) {
	changed := false
	if on, has := c.statusline.?; has && state.settings.claude_usage_statusline_off == on {
		state.settings.claude_usage_statusline_off = !on
		changed = true
	}
	if on, has := c.background.?; has && state.settings.claude_usage_background_off == on {
		state.settings.claude_usage_background_off = !on
		changed = true
	}
	return {ok = true}, changed
}

// ---- the tabs ----

// How a Claude tab's start set its status line (usage_claude_inject).
Usage_Wrap :: enum u8 {
	Wrapped, // --settings names `deckhand statusline`
	Off, // the switch is off
	No_Cli, // no deckhand CLI in this build
	Managed, // managed settings set a status line, or allow managed hooks only: they win
	Hooks_Off, // disableAllHooks: Claude Code runs no status line
	Own_Settings, // the user's own --settings flag sets a status line or names a file: left alone
	Bad_Sources, // a --setting-sources value Claude Code would refuse: left alone
}

// The settings files Claude Code reads for a tab (--setting-sources: user, project, local; all
// when it is not given). Managed settings and --settings are read whatever it says.
Usage_Setting_Source :: enum u8 {Local, Project, User}
Usage_Sources :: bit_set[Usage_Setting_Source]
USAGE_SOURCES_ALL :: Usage_Sources{.Local, .Project, .User}

// The last --setting-sources (or --setting-sources=) of a tab's flags: a comma-separated list of
// user, project and local (spaces around each allowed, "" none). ok false: one Claude Code would
// refuse (another word, or the flag without its value).
usage_setting_sources :: proc(args: []string) -> (src: Usage_Sources, ok: bool) {
	src, ok = USAGE_SOURCES_ALL, true
	value, given := "", false
	for a, i in args {
		if a == "--setting-sources" {
			if i + 1 >= len(args) do return {}, false
			value, given = args[i + 1], true
		} else if strings.has_prefix(a, "--setting-sources=") {
			value, given = a[len("--setting-sources="):], true
		}
	}
	if !given do return
	src = {}
	if strings.trim_space(value) == "" do return
	for part in strings.split(value, ",", context.temp_allocator) {
		switch strings.trim_space(part) {
		case "user":    src += {.User}
		case "project": src += {.Project}
		case "local":   src += {.Local}
		case:           return {}, false
		}
	}
	return
}

// The settings files a Claude tab started with these (effective) flags reads: its
// --setting-sources, and none at all in a restricted session (--restricted, or a truthy
// CLAUDE_CODE_RESTRICTED in the environment a tab gets: Claude Code 2.1.332 reads only managed
// settings and --settings then). ok false: a --setting-sources Claude Code would refuse.
usage_claude_sources :: proc(args: []string) -> (src: Usage_Sources, ok: bool) {
	src, ok = usage_setting_sources(args)
	if !ok do return
	if slice.contains(args, "--restricted") || usage_claude_restricted_env() do src = {}
	return
}

// CLAUDE_CODE_RESTRICTED as a Claude tab would get it (child_env: the shell environment as
// refreshed, the scrubs applied), truthy as Claude Code reads it: 1, true, yes or on, in any case,
// spaces trimmed.
@(private = "file")
usage_claude_restricted_env :: proc() -> bool {
	for e in child_env(nil) do if strings.has_prefix(e, "CLAUDE_CODE_RESTRICTED=") {
		v := strings.to_lower(strings.trim_space(e[len("CLAUDE_CODE_RESTRICTED="):]), context.temp_allocator)
		return v == "1" || v == "true" || v == "yes" || v == "on"
	}
	return false
}

@(private = "file")
Usage_Tab :: struct {
	dir:     string, // heap: its account's config folder
	cwd:     string, // heap: where it started (its project's settings)
	wrap:    Usage_Wrap,
	sources: Usage_Sources, // the settings files its flags let Claude Code read
	last:    Usage_Live, // its last report's numbers (spend: heap), applied or not
	has_last: bool,
}

// Whether two reports say the same numbers.
@(private = "file")
usage_live_same :: proc(a, b: Usage_Live) -> bool {
	if a.n != b.n || a.spend != b.spend do return false
	for i in 0 ..< a.n {
		x, y := a.windows[i], b.windows[i]
		if x.used_percent != y.used_percent || x.resets_at != y.resets_at || x.window_mins != y.window_mins do return false
	}
	return true
}

@(private = "file")
usage_tabs: map[u64]Usage_Tab

// A Claude tab started (claude_start): its account, folder and how its status line was set.
usage_claude_tab_started :: proc(tab_id: u64, dir, cwd: string, wrap: Usage_Wrap, sources: Usage_Sources) {
	heap := runtime.heap_allocator()
	if usage_tabs == nil do usage_tabs = make(map[u64]Usage_Tab, heap)
	if old, has := usage_tabs[tab_id]; has {
		delete(old.dir, heap)
		delete(old.cwd, heap)
		delete(old.last.spend, heap)
	}
	usage_tabs[tab_id] = {dir = strings.clone(dir, heap), cwd = strings.clone(cwd, heap), wrap = wrap, sources = sources}
}

// The tabs gone since (usage_tick, once a second).
usage_claude_tabs_tidy :: proc() {
	heap := runtime.heap_allocator()
	gone := make([dynamic]u64, context.temp_allocator)
	for id in usage_tabs {
		_, _, ct := claude_tab_of(id)
		if ct == nil || harness_is_codex(ct.harness) do append(&gone, id)
	}
	for id in gone {
		t := usage_tabs[id]
		delete(t.dir, heap)
		delete(t.cwd, heap)
		delete(t.last.spend, heap)
		delete_key(&usage_tabs, id)
	}
}

when TEST_HOOKS {
	usage_claude_tabs_reset_for_test :: proc() {
		heap := runtime.heap_allocator()
		for _, t in usage_tabs {
			delete(t.dir, heap)
			delete(t.cwd, heap)
			delete(t.last.spend, heap)
		}
		clear(&usage_tabs)
	}
	// Tests: how a tab's start set its status line (ok false: not recorded).
	usage_claude_tab_wrap_for_test :: proc(tab_id: u64) -> (Usage_Wrap, bool) {
		t, has := usage_tabs[tab_id]
		return t.wrap, has
	}
}

// Why a running tab of the account sends no live numbers, the row's quiet line ("" = none, or
// the switch is off). Temp.
usage_claude_live_note :: proc(dir: string) -> string {
	if !usage_claude_statusline_on() do return ""
	worst := Usage_Wrap.Wrapped
	for _, t in usage_tabs do if t.dir == dir {
		switch t.wrap {
		case .Managed:      worst = .Managed
		case .Hooks_Off:    if worst != .Managed do worst = .Hooks_Off
		case .Own_Settings, .Bad_Sources: if worst == .Wrapped do worst = t.wrap
		case .Wrapped, .Off, .No_Cli:
		}
	}
	switch worst {
	case .Managed:      return "managed status line: no live numbers from its tabs"
	case .Hooks_Off:    return "status line off (disableAllHooks): a tab sends no live numbers"
	case .Own_Settings: return "a tab's own --settings: its status line is not wrapped"
	case .Bad_Sources:  return "a tab's --setting-sources could not be read: its status line is not wrapped"
	case .Wrapped, .Off, .No_Cli:
	}
	return ""
}

// ---- the settings files ----

@(private = "file")
SETTINGS_FILE_MAX :: 1 << 20 // a settings file larger than this is not looked into

// A settings file's top-level object (temp): a regular file (never a FIFO or a device: a read
// would block) of at most SETTINGS_FILE_MAX, strict JSON. nil: none, or not that. Opened
// non-blocking and checked once open (fstat), so nothing swapped in after a check is waited on;
// a link is followed (a dotfiles manager's settings.json is one).
usage_settings_object :: proc(path: string) -> json.Object {
	if path == "" do return nil
	fd := posix.open(strings.clone_to_cstring(path, context.temp_allocator), {.NONBLOCK, .CLOEXEC})
	if fd < 0 do return nil
	defer posix.close(fd)
	st: posix.stat_t
	if posix.fstat(fd, &st) != .OK || !posix.S_ISREG(st.st_mode) || i64(st.st_size) > SETTINGS_FILE_MAX do return nil
	buf := make([]u8, int(st.st_size) + 1, context.temp_allocator) // one more: a file grown since is too big
	n := 0
	for n < len(buf) {
		room := len(buf) - n
		got := posix.read(fd, raw_data(buf[n:]), uint(room))
		if got < 0 && posix.errno() == .EINTR do continue
		if got <= 0 do break
		n += int(got)
	}
	if n > SETTINGS_FILE_MAX || n == len(buf) do return nil
	o, _ := usage_settings_parse(string(buf[:n]))
	return o
}

usage_settings_parse :: proc(text: string) -> (json.Object, bool) {
	v, jerr := jg.parse_string(text, .JSON, true, context.temp_allocator)
	if jerr != nil do return nil, false
	o, is := v.(json.Object) // an empty one ("{}") is nil, and still an object
	return o, is
}

// Claude Code's managed settings: managed-settings.json, then managed-settings.d/*.json (its
// macOS and Linux folders). An MDM profile or server-managed settings are not seen here. Temp.
@(private = "file")
usage_managed_objects :: proc() -> []json.Object {
	out := make([dynamic]json.Object, context.temp_allocator)
	dir := ODIN_OS == .Darwin ? "/Library/Application Support/ClaudeCode" : "/etc/claude-code"
	when TEST_HOOKS {
		if d, set := hook_lookup(.Claude_Managed_Dir); set do dir = d // tests: a fake folder ("" = none)
	}
	if dir == "" do return nil
	if o := usage_settings_object(strings.concatenate({dir, "/managed-settings.json"}, context.temp_allocator)); o != nil do append(&out, o)
	entries, _ := os.read_all_directory_by_path(strings.concatenate({dir, "/managed-settings.d"}, context.temp_allocator), context.temp_allocator)
	n := 0
	for e in entries do if e.type == .Regular && strings.has_suffix(e.name, ".json") && !strings.has_prefix(e.name, ".") && n < 32 {
		n += 1
		if o := usage_settings_object(e.fullpath); o != nil do append(&out, o)
	}
	return out[:]
}

// The settings files of a tab, highest first: local, project, then the account's user settings;
// "" for one its --setting-sources leaves out.
@(private = "file")
usage_settings_paths :: proc(dir, cwd: string, sources: Usage_Sources) -> [3]string {
	p: [3]string
	if cwd != "" && strings.has_prefix(cwd, "/") {
		base := strings.trim_right(cwd, "/")
		if .Local in sources do p[0] = strings.concatenate({base, "/.claude/settings.local.json"}, context.temp_allocator)
		if .Project in sources do p[1] = strings.concatenate({base, "/.claude/settings.json"}, context.temp_allocator)
	}
	if dir != "" && .User in sources do p[2] = strings.concatenate({strings.trim_right(dir, "/"), "/settings.json"}, context.temp_allocator)
	return p
}

// A user's status line (a settings file's statusLine of type command).
Usage_Status_Line :: struct {
	command:  string,
	padding:  Maybe(f64),
	refresh:  Maybe(f64), // refreshInterval, seconds
	hide_vim: Maybe(bool), // hideVimModeIndicator
}

@(private = "file")
usage_status_line_of :: proc(x: json.Object) -> (sl: Usage_Status_Line, ok: bool) {
	if x == nil do return
	if string(x["type"].(json.String) or_else "") != "command" do return
	sl.command = string(x["command"].(json.String) or_else "")
	if strings.trim_space(sl.command) == "" do return {}, false
	num :: proc(v: json.Value) -> Maybe(f64) {
		#partial switch n in v {
		case json.Integer: return f64(n)
		case json.Float:   return math.is_nan(f64(n)) ? nil : f64(n)
		}
		return nil
	}
	sl.padding = num(x["padding"])
	sl.refresh = num(x["refreshInterval"])
	if b, bok := x["hideVimModeIndicator"].(json.Boolean); bok do sl.hide_vim = bool(b)
	return sl, true
}

// Deckhand's own status line, exactly as injected (this build's CLI, quoted, then " statusline":
// a user who copied it into their settings): never run again. Another command naming deckhand
// is the user's (DECKHAND_STATUSLINE_DEPTH stops one that runs this again).
@(private = "file")
usage_status_line_ours :: proc(cmd: string) -> bool {
	cli := claude_cli_path()
	return cli != "" && strings.trim_space(cmd) == strings.concatenate({sh_quote(cli), " statusline"}, context.temp_allocator)
}

// The user's own status line for an account and a project folder: statusLine merged as Claude
// Code merges settings (the account's user settings, then the project's, then local, each key
// over the one before; only the files sources lets it read), below its flags and managed
// settings. ok false: none (or not a command).
usage_claude_user_statusline :: proc(dir, cwd: string, sources := USAGE_SOURCES_ALL) -> (sl: Usage_Status_Line, ok: bool) {
	paths := usage_settings_paths(dir, cwd, sources)
	merged: json.Object
	for i := len(paths) - 1; i >= 0; i -= 1 {
		o := usage_settings_object(paths[i])
		if o == nil do continue
		x, is := o["statusLine"].(json.Object)
		if !is do continue
		if merged == nil do merged = make(json.Object, context.temp_allocator)
		for k, v in x do merged[k] = v
	}
	sl, ok = usage_status_line_of(merged)
	if ok && usage_status_line_ours(sl.command) do return {}, false
	return
}

// The environment a wrapped tab gets for its own status line, which `deckhand statusline` runs
// only when Deckhand does not answer (a core restart or handover, a slow answer, the account
// removed): DECKHAND_STATUSLINE_USER=<command>, as resolved at this start (empty when there is
// none, so the name is always Deckhand's own; "" = not wrapped: nothing set). Nothing
// new is trusted: the command is the user's own settings', which Claude Code would run itself,
// and only Claude Code's status line run (its process's environment, set here) reads it.
usage_claude_fallback_env :: proc(dir, cwd: string, sources: Usage_Sources, wrap: Usage_Wrap) -> string {
	if wrap != .Wrapped do return ""
	sl, ok := usage_claude_user_statusline(dir, cwd, sources)
	if !ok || strings.contains_rune(sl.command, 0) do return "DECKHAND_STATUSLINE_USER=" // set, empty: never one inherited
	return strings.concatenate({"DECKHAND_STATUSLINE_USER=", sl.command}, context.temp_allocator)
}

// disableAllHooks as Claude Code would take it: managed first, then the flag's settings (given),
// then local, project and user; the first that says it decides.
@(private = "file")
usage_hooks_off :: proc(managed: []json.Object, flag: json.Object, dir, cwd: string, sources: Usage_Sources) -> bool {
	say :: proc(o: json.Object) -> (off, said: bool) {
		b, is := o["disableAllHooks"].(json.Boolean)
		return bool(b), is
	}
	for o in managed do if off, said := say(o); said && off do return true
	if flag != nil do if off, said := say(flag); said do return off
	for p in usage_settings_paths(dir, cwd, sources) {
		o := usage_settings_object(p)
		if o == nil do continue
		if off, said := say(o); said do return off
	}
	return false
}

// ---- the injection (claude_start) ----

// A tab's start with its status line: `--settings <json>` naming the CLI's statusline, after
// --plugin-dir (insert), and the user's flags (args) as they go. A user's own --settings (or
// --settings=) that is an inline JSON object without a statusLine gets ours merged into it, the
// rest of it as written; one that names a file, sets a statusLine, or does not parse is left as
// it is and the tab is not wrapped. Managed settings that set a status line (or allow managed
// hooks only) and disableAllHooks anywhere leave it unwrapped too: Claude Code would not run it.
// The user's statusLine's padding, refreshInterval and hideVimModeIndicator are copied, so the
// footer looks as it did. Temp.
usage_claude_inject :: proc(args: []string, cli, dir, cwd: string) -> (insert: []string, out_args: []string, wrap: Usage_Wrap) {
	out_args = args
	if !usage_claude_statusline_on() do return nil, args, .Off
	if cli == "" do return nil, args, .No_Cli
	sources, sok := usage_claude_sources(args)
	if !sok do return nil, args, .Bad_Sources
	managed := usage_managed_objects()
	for o in managed {
		if _, has := o["statusLine"]; has do return nil, args, .Managed
		if b, is := o["allowManagedHooksOnly"].(json.Boolean); is && bool(b) do return nil, args, .Managed
	}
	// the user's own --settings (the last one counts)
	at, inline := -1, false
	value := ""
	for a, i in args {
		if a == "--settings" && i + 1 < len(args) {
			at, value, inline = i + 1, args[i + 1], false
		} else if strings.has_prefix(a, "--settings=") {
			at, value, inline = i, a[len("--settings="):], true
		}
	}
	flag: json.Object
	if at >= 0 {
		v := strings.trim_space(value)
		if !strings.has_prefix(v, "{") do return nil, args, .Own_Settings // a file: Claude Code's to read
		is_obj: bool
		flag, is_obj = usage_settings_parse(v)
		if !is_obj do return nil, args, .Own_Settings
		if _, has := flag["statusLine"]; has do return nil, args, .Own_Settings
	}
	if usage_hooks_off(managed, flag, dir, cwd, sources) do return nil, args, .Hooks_Off
	ours := usage_claude_settings_json(cli, dir, cwd, sources)
	if at < 0 {
		insert = make([]string, 2, context.temp_allocator)
		insert[0], insert[1] = "--settings", ours
		return insert, args, .Wrapped
	}
	// merged into theirs: their text up to its closing brace, then our member
	v := strings.trim_space(value)
	body := strings.trim_space(v[1:len(v) - 1])
	member := ours[1:len(ours) - 1] // "statusLine":{…}
	merged := body == "" ? strings.concatenate({"{", member, "}"}, context.temp_allocator) : strings.concatenate({"{", body, ",", member, "}"}, context.temp_allocator)
	list := make([]string, len(args), context.temp_allocator)
	copy(list, args)
	list[at] = inline ? strings.concatenate({"--settings=", merged}, context.temp_allocator) : merged
	return nil, list, .Wrapped
}

// The settings a wrapped tab gets: {"statusLine":{"type":"command","command":"'<cli>' statusline",
// …the user's padding, refreshInterval, hideVimModeIndicator}}. Temp.
usage_claude_settings_json :: proc(cli, dir, cwd: string, sources := USAGE_SOURCES_ALL) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"statusLine":{"type":"command","command":`)
	json_quote(&b, strings.concatenate({sh_quote(cli), " statusline"}, context.temp_allocator))
	if sl, ok := usage_claude_user_statusline(dir, cwd, sources); ok {
		if p, has := sl.padding.?; has do fmt.sbprintf(&b, `,"padding":%d`, i64(clamp(p, -1000, 1000)))
		if r, has := sl.refresh.?; has && r >= 1 do fmt.sbprintf(&b, `,"refreshInterval":%d`, i64(min(r, 86400)))
		if h, has := sl.hide_vim.?; has do fmt.sbprintf(&b, `,"hideVimModeIndicator":%v`, h)
	}
	strings.write_string(&b, "}}")
	return strings.to_string(b)
}

// ---- live: claude.usage ----

// From a Claude tab's `deckhand statusline`: the plan numbers of its status line's rate_limits,
// nothing else (never the transcript, folder, session or model). Answered with the tab's own
// status line command (data {command}), which the CLI runs.
Claude_Usage_Report :: struct {
	tab_id:           u64 `cmd:"opt"`,
	five_hour:        f64 `cmd:"opt,def=-1"`, // percent used (0..100; -1 = not said)
	five_hour_resets: i64 `cmd:"opt,signed"`, // Unix seconds (0 = not said)
	seven_day:        f64 `cmd:"opt,def=-1"`,
	seven_day_resets: i64 `cmd:"opt,signed"`,
	spend:            f64 `cmd:"opt,def=-1"`, // a gateway's spend limit: percent used
	spend_resets:     i64 `cmd:"opt,signed"`,
	spend_used_usd:   f64 `cmd:"opt,def=-1"`,
	spend_limit_usd:  f64 `cmd:"opt,def=-1"`,
}

// What a report says, checked (usage_claude_live).
Usage_Live :: struct {
	windows: [2]Usage_Window, // the main ones: 5h, then 7d
	n:       int,
	spend:   string, // "spend $12.50 of $50.00", "spend 25%" ("" = not said)
}

USAGE_TIME_MAX :: 32503680000 // the year 3000: a later reset time is not one

// The numbers of a report, checked: a percent clamped to 0..100 and unknown (-1) when below 0; a
// reset time between 0 and the year 3000, else not said; a window with neither is left out.
usage_claude_live_of :: proc(c: Claude_Usage_Report) -> Usage_Live {
	l: Usage_Live
	window :: proc(l: ^Usage_Live, pct: f64, resets: i64, mins: i64) {
		w := Usage_Window{used_percent = usage_clamp_percent(pct), window_mins = mins}
		if resets > 0 && resets < USAGE_TIME_MAX do w.resets_at = resets
		if w.used_percent < 0 && w.resets_at == 0 do return
		l.windows[l.n] = w
		l.n += 1
	}
	window(&l, c.five_hour, c.five_hour_resets, 5 * 60)
	window(&l, c.seven_day, c.seven_day_resets, 7 * 24 * 60)
	money :: proc(x: f64) -> bool {return !math.is_nan(x) && !math.is_inf(x) && x >= 0 && x < 1e9}
	pct := usage_clamp_percent(c.spend)
	switch {
	case money(c.spend_used_usd) && money(c.spend_limit_usd) && c.spend_limit_usd > 0:
		l.spend = fmt.tprintf("spend $%.2f of $%.2f", c.spend_used_usd, c.spend_limit_usd)
	case pct >= 0:
		l.spend = fmt.tprintf("spend %d%%", int(math.round(pct)))
	}
	return l
}

// claude.usage (run_command): the tab's own report (caller_may), of a Claude Code tab whose
// account is configured.
usage_claude_report_apply :: proc(c: Claude_Usage_Report) -> (Result, bool) {
	s, tab, ct := claude_tab_of(c.tab_id)
	if ct == nil || harness_is_codex(ct.harness) do return fail("no such Claude tab"), false
	if !claude_account_known(ct.account, .Claude) do return fail("this tab's account is no longer configured"), false
	dir := claude_account_dir(ct.account, .Claude)
	if _, has := usage_tabs[c.tab_id]; !has {
		// a tab started by an earlier core: its folder as claude_start picks it (its own, a
		// worktree or a subfolder, while it is one; else its session's), its saved flags' sources
		// (an agent's start had none: all of them)
		// sources: claude_start's (its saved flags with the Default flags line), and never more than
		// its saved flags alone allow, the defaults having perhaps changed since (fail closed)
		cwd := tab.cwd != "" && os.is_dir(tab.cwd) ? tab.cwd : (s != nil ? s.cwd : "")
		with, wok := usage_claude_sources(claude_with_defaults(ct.args))
		own, ook := usage_claude_sources(ct.args)
		sok := wok && ook
		usage_claude_tab_started(c.tab_id, dir, cwd, sok ? .Wrapped : .Bad_Sources, sok ? with & own : {})
	}
	t := &usage_tabs[c.tab_id]
	cwd, sources := t.cwd, t.sources
	// only a tab's new numbers: its footer re-sends the same at each redraw and refreshInterval,
	// and an idle tab's never hide newer ones (usage_claude_live)
	live := usage_claude_live_of(c)
	if !t.has_last || !usage_live_same(t.last, live) {
		heap := runtime.heap_allocator()
		delete(t.last.spend, heap)
		t.last = live
		t.last.spend = strings.clone(live.spend, heap)
		t.has_last = true
		if usage_claude_statusline_on() {
			label := ""
			for a in claude_accounts(.Claude) do if a.dir == dir do label = a.label
			usage_claude_live(dir, label, live)
		}
	}
	sl, ok := usage_claude_user_statusline(dir, cwd, sources)
	if !ok do return {ok = true, data = "{}"}, false
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"command":`)
	json_quote(&b, sl.command)
	strings.write_byte(&b, '}')
	return {ok = true, data = strings.to_string(b)}, false
}

// ---- in the background: get_usage ----

// The claude flags of a background read: print mode with the SDK's stream-json on both sides, no
// session saved, no hooks of the user's run (SessionStart and the rest), no MCP server started
// (unless a managed-mcp.json forbids --strict-mcp-config). Temp.
usage_claude_flags :: proc() -> []string {
	out := make([dynamic]string, context.temp_allocator)
	append(&out, "--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence", "--settings", `{"disableAllHooks":true}`)
	managed_mcp := ODIN_OS == .Darwin ? "/Library/Application Support/ClaudeCode/managed-mcp.json" : "/etc/claude-code/managed-mcp.json"
	if !os.exists(managed_mcp) do append(&out, "--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`)
	return out[:]
}

// The shell line that runs a headless claude for an account's config folder ("" = none: not
// configured). Its account as a tab's gets it (set after the login profile; nothing for the
// default), claude found as a tab finds it, claude.ai's MCP servers and the IDE link off. Heap.
usage_claude_script :: proc(dir: string) -> string {
	account := dir == claude_account_dir("", .Claude) ? "" : dir
	if account != "" && !claude_account_known(account, .Claude) do return ""
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "set --")
	for f in usage_claude_flags() {
		strings.write_byte(&b, ' ')
		strings.write_string(&b, sh_quote(f))
	}
	strings.write_string(&b, "; ")
	for e in claude_account_env(account, .Claude) do if strings.has_prefix(e, "DECKHAND_CLAUDE_ACCOUNT=") {
		fmt.sbprintf(&b, "DECKHAND_CLAUDE_ACCOUNT=%s; ", sh_quote(e[len("DECKHAND_CLAUDE_ACCOUNT="):]))
	}
	// no update of Claude Code itself, nor the official marketplace installed, from a read
	strings.write_string(&b, "ENABLE_CLAUDEAI_MCP_SERVERS=false; CLAUDE_CODE_AUTO_CONNECT_IDE=0; CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1; DISABLE_AUTOUPDATER=1; CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1; export ENABLE_CLAUDEAI_MCP_SERVERS CLAUDE_CODE_AUTO_CONNECT_IDE CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL DISABLE_AUTOUPDATER CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL; ")
	strings.write_string(&b, CLAUDE_ACCOUNT_SH)
	cmd := ""
	when TEST_HOOKS {
		cmd = hook_env(.Claude_Cmd) // a stand-in (never the real claude in test mode: usage_read_start)
	}
	if cmd == "" do cmd = strings.concatenate({harness_found_sh(harness_path(.Claude)), CLAUDE_TAB_CMD}, context.temp_allocator)
	strings.write_string(&b, cmd)
	return strings.clone(strings.to_string(b))
}

USAGE_CLAUDE_INIT_ID :: "deckhand-usage-1"
USAGE_CLAUDE_READ_ID :: "deckhand-usage-2"

// The control requests Deckhand sends (tests read them too).
usage_claude_requests :: proc() -> (init, read: string) {
	init = `{"type":"control_request","request_id":"` + USAGE_CLAUDE_INIT_ID + `","request":{"subtype":"initialize"}}`
	read = `{"type":"control_request","request_id":"` + USAGE_CLAUDE_READ_ID + `","request":{"subtype":"get_usage","skip_behaviors":true}}`
	return
}

// Runs the exchange and parses its answer (heap; any thread).
usage_claude_read :: proc(script: string) -> ^Usage_Read {
	Talk :: struct {
		init_reply, read_reply: string,
	}
	talk: Talk
	init, _ := usage_claude_requests()
	why := usage_exchange(script, {prog = "claude", what = "claude", none = "claude ended without an answer (is Claude Code installed and new enough?)"}, init, &talk, proc(data: rawptr, line: string) -> (st: Usage_Step) {
		t := (^Talk)(data)
		id, ok := usage_claude_response_id(line)
		if !ok do return // its own messages, a login profile's output: skipped
		switch id {
		case USAGE_CLAUDE_INIT_ID:
			if t.init_reply != "" do return
			t.init_reply = line
			_, read := usage_claude_requests()
			st.send = make([]string, 1, context.temp_allocator) // outlives this step: never a literal's stack
			st.send[0] = read
			st.answered = true
		case USAGE_CLAUDE_READ_ID:
			if t.init_reply == "" do return
			t.read_reply = line
			st.done = true
		}
		return
	})
	if why != "" {
		r := new(Usage_Read, runtime.heap_allocator())
		r.status = .Error
		r.error = strings.clone(why, runtime.heap_allocator())
		return r
	}
	return usage_claude_parse(talk.init_reply, talk.read_reply)
}

// A control_response's request_id, from one line.
@(private = "file")
usage_claude_response_id :: proc(line: string) -> (id: string, ok: bool) {
	if !strings.has_prefix(line, "{") do return "", false
	v, err := jg.parse_string(line, .JSON, true, context.temp_allocator)
	if err != nil do return "", false
	o, is := v.(json.Object)
	if !is || string(o["type"].(json.String) or_else "") != "control_response" do return "", false
	r, ris := o["response"].(json.Object)
	if !ris do return "", false
	s, sis := r["request_id"].(json.String)
	return string(s), sis
}

// The answers' meaning (heap). Pure; tests feed it the schema's shapes (Claude Code 2.1.332's
// SDKControlGetUsageResponse, marked experimental): read loosely, unknown fields ignored, a
// missing or wrongly typed one "not said".
usage_claude_parse :: proc(init_reply, read_reply: string) -> ^Usage_Read {
	heap := runtime.heap_allocator()
	r := new(Usage_Read, heap)
	r.windows = make([dynamic]Usage_Window, heap)
	fail :: proc(r: ^Usage_Read, why: string) -> ^Usage_Read {
		r.status = .Error
		r.error = strings.clone(cut_utf8(usage_strip_emails(one_line(why, context.temp_allocator)), USAGE_ERROR_MAX), runtime.heap_allocator())
		return r
	}
	answer :: proc(line: string) -> (resp: json.Object, err: string, ok: bool) {
		v, jerr := jg.parse_string(line, .JSON, true, context.temp_allocator)
		if jerr != nil do return nil, "", false
		o, _ := v.(json.Object)
		res, _ := o["response"].(json.Object)
		if res == nil do return nil, "", false
		if string(res["subtype"].(json.String) or_else "") == "error" {
			e := string(res["error"].(json.String) or_else "")
			return nil, e != "" ? e : "refused", true
		}
		inner, _ := res["response"].(json.Object)
		return inner, "", true
	}
	str :: proc(o: json.Object, k: string) -> string {return string(o[k].(json.String) or_else "")}
	init, ierr, iok := answer(init_reply)
	if !iok do return fail(r, "Claude Code's initialize answer was not JSON")
	if ierr != "" do return fail(r, fmt.tprintf("Claude Code refused to initialize: %s", ierr))
	usage, uerr, uok := answer(read_reply)
	if !uok do return fail(r, "Claude Code's get_usage answer was not JSON")
	if uerr != "" do return fail(r, uerr)
	if usage == nil do return fail(r, "Claude Code's get_usage answer had no result")
	// the sign-in, from initialize's account (only these words; never its email or organization)
	acct, _ := init["account"].(json.Object)
	provider := str(acct, "apiProvider")
	r.plan = strings.clone(cut_utf8(one_line(str(usage, "subscription_type"), context.temp_allocator), USAGE_TEXT_MAX), heap)
	available := bool(usage["rate_limits_available"].(json.Boolean) or_else false)
	limits, _ := usage["rate_limits"].(json.Object)
	if !available || limits == nil {
		switch provider {
		case "", "firstParty":
			if str(acct, "apiKeySource") != "" do r.status = .No_Limits // an API key
			else if str(acct, "subscriptionType") != "" || r.plan != "" do return fail(r, "Claude Code could not read this plan's limits")
			else if str(acct, "tokenSource") != "" do r.status = .No_Limits // a token of its own (CLAUDE_CODE_OAUTH_TOKEN…)
			else do r.status = .Signed_Out
		case "bedrock":  r.status, r.no_limits_why = .No_Limits, strings.clone("Bedrock", heap)
		case "vertex":   r.status, r.no_limits_why = .No_Limits, strings.clone("Vertex", heap)
		case "foundry":  r.status, r.no_limits_why = .No_Limits, strings.clone("Foundry", heap)
		case "gateway":  r.status, r.no_limits_why = .No_Limits, strings.clone("a gateway", heap)
		case:            r.status, r.no_limits_why = .No_Limits, strings.clone(cut_utf8(one_line(provider, context.temp_allocator), USAGE_TEXT_MAX), heap)
		}
		return r
	}
	window :: proc(r: ^Usage_Read, o: json.Object, name: string, mins: i64) {
		if o == nil || len(r.windows) >= USAGE_WINDOWS_MAX do return
		w := Usage_Window{used_percent = -1, window_mins = mins}
		#partial switch u in o["utilization"] {
		case json.Integer: w.used_percent = usage_clamp_percent(f64(u))
		case json.Float:   w.used_percent = usage_clamp_percent(f64(u))
		}
		w.resets_at = usage_iso_time(string(o["resets_at"].(json.String) or_else ""))
		if w.used_percent < 0 && w.resets_at == 0 do return
		w.name = strings.clone(cut_utf8(one_line(name, context.temp_allocator), USAGE_TEXT_MAX), runtime.heap_allocator())
		append(&r.windows, w)
	}
	WEEK :: 7 * 24 * 60
	obj :: proc(o: json.Object, k: string) -> json.Object {
		x, _ := o[k].(json.Object)
		return x
	}
	window(r, obj(limits, "five_hour"), "", 5 * 60)
	window(r, obj(limits, "seven_day"), "", WEEK)
	window(r, obj(limits, "seven_day_opus"), "Opus", WEEK)
	window(r, obj(limits, "seven_day_sonnet"), "Sonnet", WEEK)
	window(r, obj(limits, "seven_day_oauth_apps"), "OAuth apps", WEEK)
	if ms, is := limits["model_scoped"].(json.Array); is {
		for m in ms {
			mo, mis := m.(json.Object)
			if !mis do continue
			name := str(mo, "display_name")
			if name == "" do continue
			window(r, mo, name, WEEK)
		}
	}
	if extra, is := limits["extra_usage"].(json.Object); is && bool(extra["is_enabled"].(json.Boolean) or_else false) {
		n :: proc(o: json.Object, k: string) -> (f64, bool) {
			#partial switch x in o[k] {
			case json.Integer: return f64(x), true
			case json.Float:   return f64(x), !math.is_nan(f64(x))
			}
			return 0, false
		}
		pct := -1.0
		used, uok := n(extra, "used_credits")
		lim, lok := n(extra, "monthly_limit")
		if uok && lok && used >= 0 && lim > 0 do pct = usage_clamp_percent(used / lim * 100)
		else if u, ok := n(extra, "utilization"); ok do pct = usage_clamp_percent(u)
		text := pct >= 0 ? fmt.tprintf("extra usage %d%% of its monthly limit", int(math.round(pct))) : "extra usage on"
		r.credits = strings.clone(text, heap)
	}
	r.limit_hit = usage_main_full(r.windows[:])
	r.status = .Ok
	return r
}

// An ISO 8601 time as Unix seconds (0 = none, or not one before the year 3000).
usage_iso_time :: proc(s: string) -> i64 {
	if s == "" do return 0
	t, n := time.rfc3339_to_time_utc(s)
	if n == 0 do t, n = time.iso8601_to_time_utc(s)
	if n == 0 do return 0
	u := time.to_unix_seconds(t)
	return u > 0 && u < USAGE_TIME_MAX ? u : 0
}

// For tests: the --settings a Claude tab of the default account gets now, as argv lines ("" = none).
usage_claude_settings_argv_for_test :: proc() -> string {
	insert, _, _ := usage_claude_inject(nil, claude_cli_path(), claude_account_dir("", .Claude), "")
	if len(insert) == 0 do return ""
	return fmt.tprintf("%s\n%s\n", insert[0], insert[1])
}
