package main

// JSON from outside Deckhand must never crash it. core:encoding/json recurses
// per nesting level (100 KB of "[" overflows the stack) and its unquote writes
// 3 bytes per invalid UTF-8 byte into a buffer sized for the input (a bounds
// trap). Each hostile input runs in a forked child, so a crash fails the test
// instead of killing the test runner.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:testing"
import "core:time"
import jg "jsonguard"

// Runs body in a forked child. ok: the child returned normally (exit 0);
// otherwise why (a signal or an exit code).
@(private = "file")
survives :: proc(body: proc()) -> (ok: bool, why: string) {
	pid := posix.fork()
	if pid == 0 {
		// the test runner's crash handlers wait for a runner thread the child does not have
		for sig in ([]posix.Signal{.SIGSEGV, .SIGBUS, .SIGILL, .SIGTRAP, .SIGABRT, .SIGFPE}) do posix.signal(sig, auto_cast posix.SIG_DFL)
		body()
		posix._exit(0)
	}
	if pid < 0 do return false, "fork failed"
	status: i32
	start := time.tick_now()
	for {
		r := posix.waitpid(pid, &status, {.NOHANG})
		if r == pid do break
		if r < 0 && posix.errno() != .EINTR do return false, "waitpid failed"
		if time.tick_since(start) > 30 * time.Second {
			posix.kill(pid, .SIGKILL)
			posix.waitpid(pid, &status, {})
			return false, "hung (killed after 30 s)"
		}
		time.sleep(5 * time.Millisecond)
	}
	if posix.WIFSIGNALED(status) do return false, fmt.tprintf("killed by signal %d", posix.WTERMSIG(status))
	if posix.WIFEXITED(status) && posix.WEXITSTATUS(status) != 0 do return false, fmt.tprintf("exit %d", posix.WEXITSTATUS(status))
	return true, ""
}

// Hostile lines: deep arrays, deep objects, and strings of invalid UTF-8
// (more than 4 bad bytes, enough to overrun unquote's slack).
HOSTILE_DEEP :: 100_000
@(private = "file")
hostile_deep_array :: proc() -> string {return strings.repeat("[", HOSTILE_DEEP, context.temp_allocator)}
@(private = "file")
hostile_deep_object :: proc() -> string {
	return strings.concatenate({strings.repeat(`{"a":`, HOSTILE_DEEP, context.temp_allocator), "1", strings.repeat("}", HOSTILE_DEEP, context.temp_allocator)}, context.temp_allocator)
}
HOSTILE_BAD_UTF8 :: "\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe\xff\xfe"
@(private = "file")
hostile_hello_bad_utf8 :: proc() -> string {
	return strings.concatenate({`{"id":"h","v":1,"type":"hello","token":"`, strings.repeat(HOSTILE_BAD_UTF8, 64, context.temp_allocator), `"}`}, context.temp_allocator)
}

// JSON5 inputs core:encoding/json's tokenizer reads differently from a naive
// scan. After "0x" it swallows the next rune unseen, whatever it is (a quote,
// a closer, a comment's '/'), and the parser ignores the Invalid_Number: a
// scan that saw that rune opens a string the parser never sees, or closes a
// level the parser keeps open. And it recurses once per comment in a row
// (get_token -> get_token), so a long run of comments overflows the stack.
HOSTILE_JSON5_N :: 60_000
@(private = "file")
hostile_json5 :: proc(n := HOSTILE_JSON5_N, comments := 1_000_000) -> [7]string {
	opens := strings.repeat("[", n, context.temp_allocator)
	return {
		strings.concatenate({`[0x"`, opens}, context.temp_allocator),
		strings.concatenate({`[0x'`, opens}, context.temp_allocator),
		strings.repeat("[0x]", n, context.temp_allocator),
		strings.repeat("[0x}", n, context.temp_allocator),
		strings.concatenate({"[0x/*", opens}, context.temp_allocator),
		strings.concatenate({"[", strings.repeat("/**/", comments / 10, context.temp_allocator), "1]"}, context.temp_allocator),
		strings.concatenate({"[", strings.repeat("//\n", comments, context.temp_allocator), "1]"}, context.temp_allocator),
	}
}

@(private = "file")
json5_now: int

@(test)
json_guard_json5_desyncs_are_refused :: proc(t: ^testing.T) {
	for s, i in hostile_json5() {
		testing.expectf(t, jg.check(s, spec = .JSON5) != .None, "JSON5 input %d passes the scan", i)
		json5_now = i
		ok, why := survives(proc() {
			s := hostile_json5()[json5_now]
			if _, err := jg.parse_string(s, .JSON5, allocator = context.temp_allocator); err == nil do posix._exit(3)
			if _, err := jg.parse_string(s, allocator = context.temp_allocator); err == nil do posix._exit(4) // the default spec
			R :: struct {extensions: []struct {name: string}}
			r: R
			wrapped := strings.concatenate({`{"extensions":`, s, "}"}, context.temp_allocator)
			if jg.unmarshal_string(wrapped, &r, .JSON5, context.temp_allocator) == nil do posix._exit(5)
			if jg.unmarshal_string(wrapped, &r, allocator = context.temp_allocator) == nil do posix._exit(6)
		})
		testing.expectf(t, ok, "JSON5 input %d: %s", i, why)
	}
}

@(test)
json_guard_parse_request_survives_hostile_lines :: proc(t: ^testing.T) {
	ok, why := survives(proc() {
		_, err := parse_request(hostile_deep_array(), context.temp_allocator)
		if err == "" do posix._exit(3)
	})
	testing.expectf(t, ok, "deep array through parse_request: %s", why)
	ok, why = survives(proc() {
		_, err := parse_request(hostile_deep_object(), context.temp_allocator)
		if err == "" do posix._exit(3)
	})
	testing.expectf(t, ok, "deep object through parse_request: %s", why)
	ok, why = survives(proc() {
		_, err := parse_request(hostile_hello_bad_utf8(), context.temp_allocator)
		if err == "" do posix._exit(3)
	})
	testing.expectf(t, ok, "invalid UTF-8 through parse_request: %s", why)
}

// The real entry: a local process connects to the control socket and sends
// one line before hello. Deckhand must answer with an error, not crash.
@(test)
json_guard_socket_survives_hostile_hello :: proc(t: ^testing.T) {
	for line, i in ([]string{hostile_deep_array(), hostile_hello_bad_utf8()}) {
		hostile_line = line
		ok, why := survives(proc() {
			dir := fmt.aprintf("%s/pd-jg-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
			os.set_env("PI_DESK_RUNTIME_DIR", dir)
			rdir, rok := sock_runtime_dir(context.temp_allocator)
			if !rok || !socket_start(rdir) do posix._exit(4)
			fd, cok := sock_connect(socket_path())
			if !cok do posix._exit(5)
			sock_write_all(fd, transmute([]u8)strings.concatenate({hostile_line, "\n"}, context.temp_allocator))
			buf: [dynamic]u8
			start := time.tick_now()
			for strings.index_byte(string(buf[:]), '\n') < 0 {
				if time.tick_since(start) > 5 * time.Second do posix._exit(6)
				if sock_wait_readable(fd, 20) {
					chunk: [4096]u8
					n := sock_read(fd, chunk[:])
					if n <= 0 do posix._exit(7)
					append(&buf, ..chunk[:n])
				}
			}
			reply := string(buf[:strings.index_byte(string(buf[:]), '\n')])
			if json_path(reply, "result.ok") != "false" do posix._exit(8)
		})
		testing.expectf(t, ok, "hostile hello %d through the control socket: %s", i, why)
	}
}

@(private = "file")
hostile_line: string

// ---- every entry point a test can reach: hostile input is refused like any bad JSON ----

@(private = "file")
Site :: struct {
	name:    string,
	refused: proc(text: string) -> bool, // true: handled as bad JSON
}

@(private = "file")
jg_tmp_file :: proc(name, text: string) -> string {
	dir := fmt.tprintf("%s/pd-jg-files-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), posix.getpid())
	os.make_directory_all(fmt.tprintf("%s/.pi-desk", dir))
	path := fmt.tprintf("%s/%s", dir, name)
	_ = os.write_entire_file(path, transmute([]u8)text)
	return path
}

@(private = "file")
SITES := [?]Site {
	{"parse_request", proc(s: string) -> bool {_, err := parse_request(s, context.temp_allocator); return err != ""}},
	{"parse_command", proc(s: string) -> bool {_, err := parse_command(s, context.temp_allocator); return err != ""}},
	{"state_from_json", proc(s: string) -> bool {_, err := state_from_json(s, context.temp_allocator); return err != ""}},
	{"workspace_restore", proc(s: string) -> bool {return workspace_restore(s) != ""}},
	{"release_parse (update manifest)", proc(s: string) -> bool {_, err := release_parse(s, context.temp_allocator); return err != ""}},
	{"app_result_of (app tab reply)", proc(s: string) -> bool {_, ok := app_result_of(s); return !ok}},
	{"app_boxes_parse (app tab event)", proc(s: string) -> bool {_, ok := app_boxes_parse(s); return !ok}},
	{"app_input_event_check", proc(s: string) -> bool {return app_input_event_check(s) != ""}},
	{"json_members_raw", proc(s: string) -> bool {_, ok := json_members_raw(s); return !ok}},
	{"json_path (ctl, scenes)", proc(s: string) -> bool {return json_path(s, "id") == "<invalid json>"}},
	{"settings_digest (pi settings.json)", proc(s: string) -> bool {return settings_digest(jg_tmp_file("settings.json", s)) == ""}},
	{"pkg_version (package.json)", proc(s: string) -> bool {return pkg_version(jg_tmp_file("package.json", s)) == ""}},
	{"pkg_name (package.json)", proc(s: string) -> bool {return pkg_name(jg_tmp_file("package.json", s)) == ""}},
	{"header_cwd (pi session header)", proc(s: string) -> bool {return header_cwd(jg_tmp_file("s.jsonl", strings.concatenate({s, "\n"}, context.temp_allocator))) == ""}},
	{"session_facts_read (pi session header)", proc(s: string) -> bool {_, err := session_facts_read(jg_tmp_file("f.jsonl", strings.concatenate({s, "\n"}, context.temp_allocator))); return err != ""}},
	{"title_scan_file (pi session lines)", proc(s: string) -> bool {
		line := strings.concatenate({`{"type":"message","message":{"role":"user","content":`, s, "}}\n"}, context.temp_allocator)
		sc: Title_Scan
		title_scan_file(jg_tmp_file("t.jsonl", line), &sc, i64(len(line)))
		return sc.first_user == ""
	}},
	{"update_load (update.json)", proc(s: string) -> bool {
		home_root = strings.trim_suffix(jg_tmp_file("x", ""), "/x")
		_ = os.write_entire_file(fmt.tprintf("%s/%s", update_data_dir(), UPDATE_FILE), transmute([]u8)s)
		upd.checks_off = false
		update_load()
		return !upd.checks_off
	}},
	{"hints_load (claude-hints.json)", proc(s: string) -> bool {
		home_root = strings.trim_suffix(jg_tmp_file("x", ""), "/x")
		_ = os.write_entire_file(fmt.tprintf("%s/%s", update_data_dir(), CLAUDE_HINTS_FILE), transmute([]u8)s)
		claude_status_reset()
		tab := Tab{id = 1 << 40, kind = Claude_Tab{}}
		tab.reload.version = "2.1.250" // older than CLAUDE_MIN_VERSION: the hint reads the file
		return claude_status_message(&tab) != ""
	}},
	{"manifest_load (pi integration extensions.json)", proc(s: string) -> bool {
		p := jg_tmp_file("extensions.json", s)
		pi_integration_override = strings.trim_suffix(p, "/extensions.json")
		pi_integration_forget()
		return len(pi_integration_optional()) == 0
	}},
	{"pi_package_find (pi settings.json, JSON5)", proc(s: string) -> bool {
		p := jg_tmp_file("settings.json", s)
		return !pi_package_find(strings.trim_suffix(p, "/settings.json"), "x").listed
	}},
	{"app_entries (.pi-desk/apps.json)", proc(s: string) -> bool {
		p := jg_tmp_file(".pi-desk/apps.json", s)
		return len(app_entries(strings.trim_suffix(p, "/.pi-desk/apps.json"))) == 0
	}},
}

@(private = "file")
site_now: int

@(test)
json_guard_every_reachable_site_refuses_hostile_json :: proc(t: ^testing.T) {
	inputs := [?]string {
		hostile_deep_array(),
		hostile_deep_object(),
		hostile_hello_bad_utf8(), // a string of invalid UTF-8 (the hello's shape: an object)
		strings.concatenate({`{"type":"x","a":"`, strings.repeat("\xc3", 64, context.temp_allocator), `"}`}, context.temp_allocator),
	}
	all := make([dynamic]string, context.temp_allocator)
	append(&all, ..inputs[:])
	json5 := hostile_json5(comments = 100_000)
	append(&all, ..json5[:])
	for site, i in SITES {
		for input, k in all {
			site_now, hostile_line = i, input
			ok, why := survives(proc() {
				if !SITES[site_now].refused(hostile_line) do posix._exit(3)
			})
			testing.expectf(t, ok, "%s, hostile input %d: %s", site.name, k, why == "exit 3" ? "accepted" : why)
		}
	}
}

// ---- the scan itself ----

@(test)
json_guard_check_refuses_what_the_parser_mishandles :: proc(t: ^testing.T) {
	R :: jg.Refusal
	cases := [?]struct {
		s:    string,
		spec: json.Specification,
		want: R,
	} {
		{`{"a":[1,{"b":"x"}]}`, .JSON, .None},
		{`{"a":"[[[[[[[[\"]]]"}`, .JSON, .None}, // brackets in strings do not count
		{"{\"a\":\"\xff\"}", .JSON, .Not_Utf8},
		{"{\"a\":\"x\ny\"}", .JSON, .Control_In_String}, // the tokenizer would end the string here
		{"{\"a\":\"x\ty\"}", .JSON, .Control_In_String},
		{`]]]]{"a":1}`, .JSON, .Unbalanced},
		// JSON5: comments and single quotes, scanned as the tokenizer scans them
		{"{a: 1 /* [[[[ */}", .JSON5, .None},
		{"{a: 1 // [[[[\n}", .JSON5, .None},
		{`{a: '[[[["'}`, .JSON5, .None},
		{`{a: '"', b: "'"}`, .JSON5, .None},
		// "**/" does not close: the tokenizer reads '*' then the byte after it as a pair
		{"/***/ [[[", .JSON5, .None},
		{"/* */ [[", .JSON5, .None},
	}
	for c in cases do testing.expectf(t, jg.check(c.s, 4, spec = c.spec) == c.want, "%q (%v): got %v, want %v", c.s, c.spec, jg.check(c.s, 4, spec = c.spec), c.want)
	// a quote inside a JSON5 comment cannot hide brackets after it
	testing.expect_value(t, jg.check("/* \" */ [[[[[", 4, spec = .JSON5), R.Too_Deep)
	testing.expect_value(t, jg.check("// \"\n[[[[[", 4, spec = .JSON5), R.Too_Deep)
	// JSON5 hex: "0x" then [0-9A-Za-z] parses; anything else after it is refused (the tokenizer swallows it unseen)
	for ok_s in ([]string{"{a: 0x1F, b: 0XaB, c: [0x0]}", "[0xg]", "{a: '0x\"'}", "// 0x\"\n[1]", "[10x]", "[-0x]", "{a0x: 1}", "[1e0x]", "0x"}) do testing.expectf(t, jg.check(ok_s, 4, spec = .JSON5) == .None, "%q: got %v", ok_s, jg.check(ok_s, 4, spec = .JSON5))
	for bad in ([]string{`[0x"]`, `[0x']`, "[0x]", "[0X}", "[0x/**/]", "[0x ]", "[0x,1]", "[0x\u00e9]"}) do testing.expectf(t, jg.check(bad, 4, spec = .JSON5) != .None, "%q passes", bad)
	testing.expect_value(t, jg.check(`["0x]"]`, 4, spec = .JSON), R.None) // strict JSON has no hex
	// JSON5 comments in a row (only whitespace between): the tokenizer recurses per comment
	COMMENT_RUN :: 64 // jg.MAX_COMMENT_RUN
	run :: proc(n: int, sep: string) -> string {return strings.concatenate({"[", strings.repeat(sep, n, context.temp_allocator), "1]"}, context.temp_allocator)}
	testing.expect_value(t, jg.check(run(COMMENT_RUN, "/**/ "), spec = .JSON5), R.None)
	testing.expect(t, jg.check(run(COMMENT_RUN + 1, "/**/ "), spec = .JSON5) != .None, "a run of block comments")
	testing.expect(t, jg.check(run(COMMENT_RUN + 1, "// x\n\t"), spec = .JSON5) != .None, "a run of line comments")
	testing.expect_value(t, jg.check(run(1000, "/**/ 1,"), spec = .JSON5), R.None) // a token between: no recursion
	// the default is strict JSON: JSON5 only when a caller asks
	testing.expect_value(t, jg.check("{a: 1 /* [[[[[ */}", 4), R.Too_Deep)
	_, derr := jg.parse_string("{a: 1}", allocator = context.temp_allocator)
	testing.expect(t, derr != nil, "the default refuses JSON5")
	_, derr = jg.parse_string("{a: 1}", .JSON5, allocator = context.temp_allocator)
	testing.expect_value(t, derr, json.Error.None)
	// in strict JSON a quote is only '"' (the tokenizer refuses ' and /)
	testing.expect_value(t, jg.check(`['  [[[[`, 4, spec = .JSON), R.Too_Deep)
	// depth: exactly the limit passes; the cap holds whatever is asked
	testing.expect_value(t, jg.check(strings.repeat("[", jg.MAX_DEPTH, context.temp_allocator)), R.None)
	testing.expect_value(t, jg.check(strings.repeat("[", jg.MAX_DEPTH + 1, context.temp_allocator)), R.Too_Deep)
	testing.expect_value(t, jg.check(strings.repeat("[", jg.DEPTH_CAP + 1, context.temp_allocator), 1 << 20), R.Too_Deep)
	// keys per object: unlimited for parse, limited for unmarshal
	many := strings.builder_make(context.temp_allocator)
	strings.write_byte(&many, '{')
	for i in 0 ..< jg.MAX_KEYS_UNMARSHAL + 1 do fmt.sbprintf(&many, `%s"k%d":1`, i > 0 ? "," : "", i)
	strings.write_byte(&many, '}')
	testing.expect_value(t, jg.check(strings.to_string(many)), R.None)
	testing.expect_value(t, jg.check(strings.to_string(many), max_keys = jg.MAX_KEYS_UNMARSHAL), R.Too_Many_Keys)
	S :: struct {k0: int}
	x: S
	testing.expect(t, jg.unmarshal_string(strings.to_string(many), &x) != nil, "unmarshal refuses an object of too many keys")
	// parse refuses with an error, like bad JSON; holderwire's API is unchanged
	v, err := jg.parse_string(strings.repeat("[", 100, context.temp_allocator), .JSON, true, context.temp_allocator)
	testing.expect(t, v == nil && err != nil, "refused as bad JSON")
	_, err = jg.parse_string(`{"a":[1,2]}`, .JSON, true, context.temp_allocator)
	testing.expect_value(t, err, json.Error.None)
	// fix_utf8 (titles): invalid bytes read as U+FFFD instead of refusing the line
	v, err = jg.parse_string(strings.concatenate({`{"a":"x`, HOSTILE_BAD_UTF8, `y"}`}, context.temp_allocator), .JSON, true, context.temp_allocator, fix_utf8 = true)
	testing.expect_value(t, err, json.Error.None)
	testing.expect_value(t, string(v.(json.Object)["a"].(json.String)), strings.concatenate({"x", strings.repeat("\uFFFD", len(HOSTILE_BAD_UTF8), context.temp_allocator), "y"}, context.temp_allocator))
}

// The limits are safe on the smallest stack a Deckhand thread gets (512 KiB:
// a secondary pthread's default; Odin threads take RLIMIT_STACK, normally 8
// MiB), in this unoptimised build, which uses more stack per level than the
// release build: parse plus marshal at MAX_DEPTH, parse at MAX_DEPTH_TRANSCRIPT.
@(test)
json_guard_limits_fit_a_small_thread_stack :: proc(t: ^testing.T) {
	ok, why := survives(proc() {
		attr: posix.pthread_attr_t
		posix.pthread_attr_init(&attr)
		posix.pthread_attr_setstacksize(&attr, 512 * 1024)
		th: posix.pthread_t
		posix.pthread_create(&th, &attr, proc "c" (_: rawptr) -> rawptr {
			context = runtime.default_context()
			deep :: proc(n: int) -> string {
				return strings.concatenate({strings.repeat(`{"a":[`, n / 2, context.temp_allocator), "1", strings.repeat("]}", n / 2, context.temp_allocator)}, context.temp_allocator)
			}
			v, err := jg.parse_string(deep(jg.MAX_DEPTH), .JSON, true, context.temp_allocator)
			if err != nil do posix._exit(3)
			if _, merr := json.marshal(v, {}, context.temp_allocator); merr != nil do posix._exit(4)
			_, err = jg.parse_string(deep(jg.MAX_DEPTH_TRANSCRIPT), .JSON, true, context.temp_allocator, max_depth = jg.MAX_DEPTH_TRANSCRIPT)
			if err != nil do posix._exit(5)
			return nil
		}, nil)
		posix.pthread_join(th, nil)
	})
	testing.expectf(t, ok, "parsing at the limits on a 512 KiB thread: %s", why)
}

// Every json.parse / json.unmarshal / json.make_parser in Deckhand's own code
// goes through jg (src/jsonguard), or sits right after a check that refuses
// the same inputs (json_valid: strict RFC 8259, UTF-8, 64 deep; jg.check /
// json_shape_ok). A new call that skips the guard fails here. Each site is
// listed with its limit, so one that moves or changes limit is noticed too.
@(test)
json_guard_every_parse_site_is_guarded :: proc(t: ^testing.T) {
	SRC := #load_directory(".")
	HOLDERWIRE := #load_directory("holderwire")
	// file, proc, call, limit ("" = the default, jg.MAX_DEPTH)
	Want :: struct {file, proc_name, call, limit: string}
	WANT := [?]Want {
		{"agent.odin", "json_field", "jg.parse_string", "transcript"}, // pi session lines
		{"app_tab.odin", "app_input_event_check", "jg.parse_string", ""},
		{"app_tab.odin", "json_string_of", "jg.parse_string", ""},
		{"app_tab.odin", "app_event_in", "json.make_parser", "json_valid"},
		{"app_tab.odin", "app_boxes_parse", "jg.parse_string", ""},
		{"app_tab.odin", "app_entries", "jg.parse", ""},
		{"autotest.odin", "json_path", "jg.parse_string", ""},
		{"browser.odin", "rlz_off", "jg.parse", ""},
		{"browser_act.odin", "act_step", "jg.parse_string", ""},
		{"browser_act.odin", "eval_reply", "jg.parse_string", ""},
		{"browser_act.odin", "act_result", "jg.parse_string", ""},
		{"browser_act.odin", "act_result", "jg.parse_string", ""},
		{"browser_act.odin", "act_result", "jg.parse_string", ""},
		{"browser_agent.odin", "browser_agent_devtools", "jg.parse", ""},
		{"browser_agent.odin", "browser_agent_devtools", "jg.parse", ""},
		{"browser_agent.odin", "op_step", "jg.parse_string", ""},
		{"browser_agent.odin", "eval_value", "jg.parse_string", ""},
		{"browser_annotate.odin", "on_cef_devtools", "jg.parse", ""},
		{"browser_annotate.odin", "on_cef_devtools", "jg.parse", ""},
		{"browser_annotate.odin", "on_cef_devtools", "jg.parse_string", ""}, // a page's binding payload
		{"claude_disk.odin", "look", "jg.parse", ""}, // Claude transcripts (seen 16 deep)
		{"claude_disk.odin", "found_cwd", "jg.parse", ""},
		{"claude_status.odin", "hints_load", "jg.parse", ""},
		{"ctl.odin", "ctl_main", "jg.parse_string", ""},
		{"harness_manifest.odin", "pi_settings_sources", "jg.parse", ""},
		{"jobs.odin", "job_load", "jg.parse", ""},
		{"jobs.odin", "s", "jg.parse", ""},
		{"jobs.odin", "ledger_ready", "jg.parse", ""},
		{"jobs_run.odin", "run_event", "jg.parse_string", "transcript"}, // pi's JSON events
		{"json_read.odin", "json_members_raw", "json.make_parser", "jg.shape_ok"},
		{"json_read.odin", "parse_command", "jg.parse_string", ""},
		{"json_read.odin", "parse_request", "jg.parse_string", ""},
		{"json_read.odin", "state_from_json", "jg.parse_string", ""},
		{"persist.odin", "workspace_restore", "jg.parse_string", ""},
		{"pi_integration.odin", "manifest_load", "jg.unmarshal", ""},
		{"reload.odin", "settings_digest", "jg.parse", ""},
		{"reload.odin", "pkg_version", "jg.parse", ""},
		{"reload.odin", "pkg_name", "jg.parse", ""},
		{"reload.odin", "add_settings_paths", "jg.parse", ""},
		{"reload.odin", "add_local", "jg.parse", ""},
		{"session_info.odin", "session_facts_read", "jg.parse_string", ""},
		{"sessions.odin", "header_cwd", "jg.parse", ""},
		{"settings_files.odin", "settings_packages", "jg.parse", ""},
		{"snapshot.odin", "snapshot_unpack", "json.parse", "json_shape_ok"},
		{"snapshot.odin", "snapshot_unpack", "json.unmarshal", "json_shape_ok"},
		{"socket.odin", "app_conn_line", "json.parse_string", "json_valid"},
		{"titles.odin", "title_line", "jg.parse", "transcript"},
		{"update.odin", "update_load", "jg.parse", ""},
		{"update_core.odin", "release_parse", "jg.parse_string", ""}, // the network
		{"holderwire/schema.odin", "schema_problems", "jg.parse_string", ""},
		{"holderwire/schema.odin", "schema_problems", "jg.parse_string", ""},
		{"holderwire/wire.odin", "decode", "json.parse", "json_shape_ok"},
		{"holderwire/wire.odin", "decode", "json.unmarshal", "json_shape_ok"},
	}
	got := make([dynamic]Want, context.temp_allocator)
	scan :: proc(got: ^[dynamic]Want, prefix: string, files: []runtime.Load_Directory_File) {
		CALLS :: [?]string{"json.parse_string(", "json.parse_bytes(", "json.parse(", "json.unmarshal_string(", "json.unmarshal_any(", "json.unmarshal(", "json.make_parser(", "jg.parse_string(", "jg.parse(", "jg.unmarshal(", "jg.unmarshal_string("}
		for f in files {
			if !strings.has_suffix(f.name, ".odin") || strings.has_suffix(f.name, "_test.odin") do continue
			lines := strings.split_lines(string(f.data), context.temp_allocator)
			proc_name := ""
			for line, i in lines {
				code := line
				if c := strings.index(code, "//"); c >= 0 do code = code[:c]
				if colon := strings.index(code, " :: proc"); colon >= 0 do proc_name = strings.trim_space(code[:colon])
				for call in CALLS {
					at := strings.index(code, call)
					if at < 0 || (at > 0 && (code[at - 1] == '_' || code[at - 1] == '.' || 'a' <= code[at - 1] && code[at - 1] <= 'z')) do continue
					limit := ""
					if strings.has_prefix(call, "jg.") {
						if strings.contains(code, "MAX_DEPTH_TRANSCRIPT") do limit = "transcript"
						else if strings.contains(code, "max_depth") do limit = "custom"
					} else {
						// a raw call: what guards it, in the 12 lines before
						limit = "UNGUARDED"
						for j := i; j >= max(0, i - 12); j -= 1 {
							for g in ([]string{"json_valid", "jg.shape_ok", "json_shape_ok"}) do if strings.contains(lines[j], strings.concatenate({g, "("}, context.temp_allocator)) {limit = g; break}
							if limit != "UNGUARDED" do break
						}
					}
					append(got, Want{strings.concatenate({prefix, f.name}, context.temp_allocator), proc_name, call[:len(call) - 1], limit})
					break
				}
			}
		}
	}
	scan(&got, "", SRC)
	scan(&got, "holderwire/", HOLDERWIRE)
	for g in got do testing.expectf(t, g.limit != "UNGUARDED", "%s %s: %s with no guard before it: use jg (src/jsonguard)", g.file, g.proc_name, g.call)
	used := make([]bool, len(got), context.temp_allocator)
	for w in WANT {
		found := false
		for g, i in got do if !used[i] && g == w {used[i], found = true, true; break}
		testing.expectf(t, found, "expected site gone or changed: %v", w)
	}
	for g, i in got do testing.expectf(t, used[i], "new JSON parse site, not in the list: %v (add it, with its limit)", g)
}
