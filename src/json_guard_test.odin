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
	run :: proc(n: int, sep: string) -> string {return strings.concatenate({"[", strings.repeat(sep, n, context.temp_allocator), "1]"}, context.temp_allocator)}
	testing.expect_value(t, jg.check(run(jg.MAX_COMMENT_RUN, "/**/ "), spec = .JSON5), R.None)
	testing.expect(t, jg.check(run(jg.MAX_COMMENT_RUN + 1, "/**/ "), spec = .JSON5) != .None, "a run of block comments")
	testing.expect(t, jg.check(run(jg.MAX_COMMENT_RUN + 1, "// x\n\t"), spec = .JSON5) != .None, "a run of line comments")
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

// Every use of core:encoding/json's parser in Deckhand's own code (src/ and
// tools/, every package; not tests, not src/jsonguard) goes through jg, or
// sits right after a check that refuses the same inputs. A parser proc is any
// lowercase json.name but marshal and the value helpers: called or not (a
// proc value is a way around jg too). Comments and string contents do not
// count, for the calls or for the guards. A guard is `!check(ARG` with the
// call's own first argument, then a return, earlier in the same proc and at
// most 12 lines before (check: json_valid: strict RFC 8259, UTF-8, 64 deep;
// jg.shape_ok / json_shape_ok). A call on a parser (&p) counts as guarded
// when its proc made that parser from guarded text. core:encoding/json
// imported under another name is refused outright. Each site is listed with
// its limit and spec, so one that moves or changes either is noticed too.
@(private = "file")
Parse_Site :: struct {file, proc_name, call, limit, spec: string}

@(private = "file")
JSON_SAFE := [?]string{"marshal", "marshal_to_builder", "marshal_to_writer", "destroy_value", "clone_value"}
@(private = "file")
JG_PARSERS := [?]string{"parse", "parse_string", "parse_bytes", "unmarshal", "unmarshal_string"}
@(private = "file")
JSON_GUARDS := [?]string{"json_valid", "jg.shape_ok", "json_shape_ok", "hw.json_shape_ok"}

// src with comments and the insides of string and rune literals blanked
// (newlines kept, so lines still line up).
@(private = "file")
code_only :: proc(src: string) -> string {
	b := make([]u8, len(src), context.temp_allocator)
	copy(b, src)
	blank :: proc(b: []u8, from, to: int) {for k in max(from, 0) ..< min(to, len(b)) do if b[k] != '\n' do b[k] = ' '}
	for i := 0; i < len(b); {
		c := b[i]
		next: u8 = i + 1 < len(b) ? b[i + 1] : 0
		switch {
		case c == '/' && next == '/':
			j := i
			for j < len(b) && b[j] != '\n' do j += 1
			blank(b, i, j)
			i = j
		case c == '/' && next == '*': // Odin's block comments nest
			depth, j := 0, i
			for j < len(b) {
				if j + 1 < len(b) && b[j] == '/' && b[j + 1] == '*' {depth += 1; j += 2}
				else if j + 1 < len(b) && b[j] == '*' && b[j + 1] == '/' {depth -= 1; j += 2; if depth == 0 do break}
				else do j += 1
			}
			blank(b, i, j)
			i = j
		case c == '"' || c == '\'':
			j := i + 1
			for j < len(b) && b[j] != c && b[j] != '\n' do j += b[j] == '\\' ? 2 : 1
			blank(b, i + 1, j)
			i = j + 1
		case c == '`':
			j := i + 1
			for j < len(b) && b[j] != '`' do j += 1
			blank(b, i + 1, j)
			i = j + 1
		case:
			i += 1
		}
	}
	return string(b)
}

@(private = "file")
ident_byte :: proc(c: u8) -> bool {return c == '_' || '0' <= c && c <= '9' || 'a' <= c && c <= 'z' || 'A' <= c && c <= 'Z'}

// The first argument of the call whose '(' is at s[open] (to the first comma
// or ')' at its own level), trimmed.
@(private = "file")
first_arg :: proc(s: string, open: int) -> string {
	depth := 0
	for k in open + 1 ..< len(s) {
		switch s[k] {
		case '(', '[', '{': depth += 1
		case ')', ']', '}':
			if depth == 0 do return strings.trim_space(s[open + 1:k])
			depth -= 1
		case ',': if depth == 0 do return strings.trim_space(s[open + 1:k])
		}
	}
	return strings.trim_space(s[open + 1:])
}

// The parse sites of one file; limit "UNGUARDED" (no guard), "ALIASED"
// (core:encoding/json imported under another name).
@(private = "file")
scan_source :: proc(file, text: string) -> []Parse_Site {
	got := make([dynamic]Parse_Site, context.temp_allocator)
	raw := strings.split_lines(text, context.temp_allocator)
	lines := strings.split_lines(code_only(text), context.temp_allocator)
	proc_name := "" // the top-level proc (the label)
	proc_start := 0 // the line of the innermost proc header (where guards stop)
	parser_guard := "" // the guard of a parser this proc made ("" = none)
	for code, i in lines {
		if colon := strings.index(code, " :: proc"); colon >= 0 {
			proc_start = i
			parser_guard = ""
			if len(code) > 0 && code[0] != ' ' && code[0] != '\t' do proc_name = strings.trim_space(code[:colon])
		}
		trimmed := strings.trim_space(code)
		if strings.has_prefix(trimmed, "import ") && strings.contains(raw[i], `"core:encoding/json"`) {
			name := strings.trim_space(strings.trim_prefix(strings.trim_space(raw[i][:strings.index(raw[i], `"`)]), "import"))
			if name != "" && name != "json" do append(&got, Parse_Site{file, proc_name, strings.concatenate({"import ", name}, context.temp_allocator), "ALIASED", ""})
			continue
		}
		for pkg in ([]string{"json.", "jg."}) {
			for at := 0; at < len(code); {
				k := strings.index(code[at:], pkg)
				if k < 0 do break
				k += at
				at = k + len(pkg)
				if k > 0 && (ident_byte(code[k - 1]) || code[k - 1] == '.') do continue
				e := at
				for e < len(code) && ident_byte(code[e]) do e += 1
				name := code[at:e]
				if name == "" || !('a' <= name[0] && name[0] <= 'z') do continue
				listed := false
				if pkg == "jg." {
					for n in JG_PARSERS do if n == name do listed = true
				} else {
					listed = true
					for n in JSON_SAFE do if n == name do listed = false
				}
				if !listed do continue
				call := strings.concatenate({pkg, name}, context.temp_allocator)
				rest := code[e:]
				open := e + (len(rest) - len(strings.trim_left_space(rest)))
				is_call := open < len(code) && code[open] == '('
				spec := ""
				if strings.contains(code, ".JSON5") || strings.contains(code, ".MJSON") || strings.contains(code, ".SJSON") do spec = "JSON5"
				limit := ""
				if pkg == "jg." {
					if strings.contains(code, "MAX_DEPTH_TRANSCRIPT") do limit = "transcript"
					else if strings.contains(code, "max_depth") do limit = "custom"
				} else if !is_call {
					limit = "UNGUARDED" // a proc value: a call through it is not seen
				} else {
					arg := first_arg(code, open)
					if strings.has_prefix(arg, "&") {
						limit = parser_guard != "" ? "parser" : "UNGUARDED"
					} else {
						if !strings.contains(code, ".JSON") do spec = "JSON5 (default)"
						limit = "UNGUARDED"
						guard: for j := i; j >= max(proc_start, i - 12); j -= 1 {
							for g in JSON_GUARDS {
								needle := strings.concatenate({"!", g, "(", arg}, context.temp_allocator)
								c := strings.index(lines[j], needle)
								if c < 0 do continue
								after := lines[j][c + len(needle):]
								if !strings.has_prefix(after, ")") && !strings.has_prefix(after, ",") do continue
								returns := strings.contains(lines[j][c:], "return")
								if !returns && strings.has_suffix(strings.trim_space(lines[j]), "{") {
									for m in j + 1 ..< min(j + 4, i) do if strings.contains(lines[m], "return") do returns = true
								}
								if !returns do continue
								limit = strings.trim_prefix(g, "hw.")
								break guard
							}
						}
						if name == "make_parser" || name == "make_parser_from_string" || name == "make_parser_from_bytes" {
							parser_guard = limit != "UNGUARDED" ? limit : ""
						}
					}
				}
				append(&got, Parse_Site{file, proc_name, call, limit, spec})
				break // one site per line
			}
		}
	}
	return got[:]
}

// Every .odin file under dir (not tests), as paths relative to the repo.
@(private = "file")
odin_sources :: proc(dir, rel: string, out: ^[dynamic][2]string) {
	entries, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil do return
	for e in entries {
		if strings.has_prefix(e.name, ".") || e.name == "node_modules" do continue
		r := strings.concatenate({rel, "/", e.name}, context.temp_allocator)
		if e.type == .Directory {
			if r != "src/jsonguard" do odin_sources(e.fullpath, r, out)
			continue
		}
		if !strings.has_suffix(e.name, ".odin") || strings.has_suffix(e.name, "_test.odin") do continue
		data, rerr := os.read_entire_file(e.fullpath, context.temp_allocator)
		if rerr == nil do append(out, [2]string{r, string(data)})
	}
}

// The scan catches the ways around it.
@(test)
json_guard_scan_sees_through_disguises :: proc(t: ^testing.T) {
	limit_of :: proc(src: string) -> string {
		got := scan_source("x.odin", src)
		if len(got) != 1 do return fmt.tprintf("%d sites", len(got))
		return got[0].limit
	}
	testing.expect_value(t, limit_of("import j \"core:encoding/json\"\n"), "ALIASED")
	testing.expect_value(t, limit_of("f :: proc() {\n\tp := json.parse_string\n}\n"), "UNGUARDED") // a proc value
	testing.expect_value(t, limit_of("f :: proc(s: string) {\n\tu := \"http://x\"; v, _ := json.parse(s)\n}\n"), "UNGUARDED") // after a // in a string
	testing.expect_value(t, limit_of("f :: proc(s: string) {\n\t// if !json_valid(s) do return\n\tv, _ := json.parse(s)\n}\n"), "UNGUARDED") // a guard in a comment
	testing.expect_value(t, limit_of("f :: proc(s, o: string) {\n\tif !json_valid(o) do return\n\tv, _ := json.parse(s)\n}\n"), "UNGUARDED") // another variable
	testing.expect_value(t, limit_of("f :: proc(s: string) {\n\tok := json_valid(s)\n\tv, _ := json.parse(s)\n}\n"), "UNGUARDED") // checked, not acted on
	testing.expect_value(t, limit_of("g :: proc(s: string) {\n\tif !json_valid(s) do return\n}\nf :: proc(s: string) {\n\tv, _ := json.parse(s)\n}\n"), "UNGUARDED") // another proc's guard
	testing.expect_value(t, limit_of("f :: proc(s: string) {\n\tif !json_valid(s) do return\n\tv, _ := json.parse(s, .JSON)\n}\n"), "json_valid")
	testing.expect_value(t, limit_of("f :: proc(s: string) {\n\tif !json_valid(s) {\n\t\tlog()\n\t\treturn\n\t}\n\tv, _ := json.parse(s, .JSON)\n}\n"), "json_valid")
	for name in ([]string{"is_valid", "parse_value", "validate_value", "unquote_string", "make_tokenizer", "get_token", "unmarshal_any"}) {
		testing.expectf(t, limit_of(fmt.tprintf("f :: proc(s: string) {{\n\tx := json.%s(s)\n}}\n", name)) == "UNGUARDED", "json.%s", name)
	}
	// json_shape_ok is holderwire's (a jg.shape_ok); a json_shape_ok of another package is not it
	testing.expect_value(t, limit_of("f :: proc(s: string) {\n\tif !json_shape_ok(s) do return\n\tv, _ := json.parse(s, .JSON)\n}\n"), "UNGUARDED")
	testing.expect_value(t, len(scan_source("src/holderwire/x.odin", "f :: proc(s: string) {\n\tif !json_shape_ok(s) do return\n\tv, _ := json.parse(s, .JSON)\n}\n")), 1)
	testing.expect_value(t, scan_source("src/holderwire/x.odin", "f :: proc(s: string) {\n\tif !json_shape_ok(s) do return\n\tv, _ := json.parse(s, .JSON)\n}\n")[0].limit, "json_shape_ok")
	testing.expect_value(t, limit_of("f :: proc(p: ^json.Parser) {\n\tv, _ := json.parse_value(p)\n}\n"), "UNGUARDED")
	testing.expect_value(t, limit_of("f :: proc() {\n\tb, _ := json.marshal(x)\n\to: json.Object\n}\n"), "0 sites")
	testing.expect_value(t, limit_of("f :: proc() {\n\ts := \"json.parse(x)\"\n}\n"), "0 sites")
}

@(test)
json_guard_every_parse_site_is_guarded :: proc(t: ^testing.T) {
	root := strings.trim_suffix(strings.trim_right(#directory, "/"), "/src")
	files := make([dynamic][2]string, context.temp_allocator)
	odin_sources(strings.concatenate({root, "/src"}, context.temp_allocator), "src", &files)
	odin_sources(strings.concatenate({root, "/tools"}, context.temp_allocator), "tools", &files)
	testing.expectf(t, len(files) > 100, "found %d .odin files under src/ and tools/", len(files))
	// file, top-level proc, call, limit ("" = jg's default, jg.MAX_DEPTH), spec ("" = strict JSON)
	WANT := [?]Parse_Site {
		{"src/agent.odin", "json_field", "jg.parse_string", "transcript", ""}, // pi session lines
		{"src/app_tab.odin", "app_input_event_check", "jg.parse_string", "", ""},
		{"src/app_tab.odin", "json_string_of", "jg.parse_string", "", ""},
		{"src/app_tab.odin", "app_event_in", "json.make_parser", "json_valid", ""},
		{"src/app_tab.odin", "app_event_in", "json.parse_value", "parser", ""},
		{"src/app_tab.odin", "app_boxes_parse", "jg.parse_string", "", ""},
		{"src/app_tab.odin", "app_entries", "jg.parse", "", ""},
		{"src/autotest.odin", "json_path", "jg.parse_string", "", ""},
		{"src/browser.odin", "rlz_off", "jg.parse", "", ""},
		{"src/browser_act.odin", "act_step", "jg.parse_string", "", ""},
		{"src/browser_act.odin", "act_step", "jg.parse_string", "", ""},
		{"src/browser_act.odin", "act_result", "jg.parse_string", "", ""},
		{"src/browser_act.odin", "act_result", "jg.parse_string", "", ""},
		{"src/browser_act.odin", "act_result", "jg.parse_string", "", ""},
		{"src/browser_agent.odin", "browser_agent_devtools", "jg.parse", "", ""},
		{"src/browser_agent.odin", "browser_agent_devtools", "jg.parse", "", ""},
		{"src/browser_agent.odin", "op_step", "jg.parse_string", "", ""},
		{"src/browser_agent.odin", "op_step", "jg.parse_string", "", ""},
		{"src/browser_annotate.odin", "on_cef_devtools", "jg.parse", "", ""},
		{"src/browser_annotate.odin", "on_cef_devtools", "jg.parse", "", ""},
		{"src/browser_annotate.odin", "on_cef_devtools", "jg.parse_string", "", ""}, // a page's binding payload
		{"src/claude_disk.odin", "found_read", "jg.parse", "", ""}, // Claude transcripts (seen 16 deep)
		{"src/claude_disk.odin", "found_cwd", "jg.parse", "", ""},
		{"src/claude_status.odin", "hints_load", "jg.parse", "", ""},
		{"src/ctl.odin", "ctl_main", "jg.parse_string", "", ""},
		{"src/harness_manifest.odin", "pi_settings_sources", "jg.parse", "", "JSON5"}, // pi's settings.json: a person edits it
		{"src/jobs.odin", "job_load", "jg.parse", "", ""},
		{"src/jobs.odin", "job_load", "jg.parse", "", ""},
		{"src/jobs.odin", "ledger_ready", "jg.parse", "", ""},
		{"src/jobs_run.odin", "run_event", "jg.parse_string", "transcript", ""}, // pi's JSON events
		{"src/json_read.odin", "json_members_raw", "json.make_parser", "jg.shape_ok", ""},
		{"src/json_read.odin", "json_members_raw", "json.advance_token", "parser", ""},
		{"src/json_read.odin", "json_members_raw", "json.expect_token", "parser", ""},
		{"src/json_read.odin", "json_members_raw", "json.parse_object_key", "parser", ""},
		{"src/json_read.odin", "json_members_raw", "json.expect_token", "parser", ""},
		{"src/json_read.odin", "json_members_raw", "json.parse_value", "parser", ""},
		{"src/json_read.odin", "json_members_raw", "json.advance_token", "parser", ""},
		{"src/json_read.odin", "parse_command", "jg.parse_string", "", ""},
		{"src/json_read.odin", "parse_request", "jg.parse_string", "", ""},
		{"src/json_read.odin", "state_from_json", "jg.parse_string", "", ""},
		{"src/persist.odin", "workspace_restore", "jg.parse_string", "", ""},
		{"src/pi_integration.odin", "manifest_load", "jg.unmarshal", "", ""},
		{"src/reload.odin", "settings_digest", "jg.parse", "", ""},
		{"src/reload.odin", "pkg_version", "jg.parse", "", ""},
		{"src/reload.odin", "pkg_name", "jg.parse", "", ""},
		{"src/reload.odin", "add_settings_paths", "jg.parse", "", ""},
		{"src/reload.odin", "add_local", "jg.parse", "", ""},
		{"src/session_info.odin", "session_facts_read", "jg.parse_string", "", ""},
		{"src/sessions.odin", "header_cwd", "jg.parse", "", ""},
		{"src/settings_files.odin", "settings_packages", "jg.parse", "", "JSON5"}, // pi's settings.json: a person edits it
		{"src/snapshot.odin", "snapshot_unpack", "json.parse", "json_shape_ok", ""},
		{"src/snapshot.odin", "snapshot_unpack", "json.unmarshal", "json_shape_ok", ""},
		{"src/socket.odin", "app_conn_line", "json.parse_string", "json_valid", ""},
		{"src/titles.odin", "title_line", "jg.parse", "transcript", ""},
		{"src/update.odin", "update_load", "jg.parse", "", ""},
		{"src/update_core.odin", "release_parse", "jg.parse_string", "", ""}, // the network
		{"src/holderwire/schema.odin", "schema_problems", "jg.parse_string", "", ""},
		{"src/holderwire/schema.odin", "schema_problems", "jg.parse_string", "", ""},
		{"src/holderwire/wire.odin", "decode", "json.parse", "json_shape_ok", ""},
		{"src/holderwire/wire.odin", "decode", "json.unmarshal", "json_shape_ok", ""},
		{"tools/pi-desk-cli/json_util.odin", "parse_obj", "jg.parse_string", "", ""}, // Claude Code's hook input (the read-only guard), Deckhand's replies
		{"tools/pi-desk-cli/args.odin", "parse_cli", "jg.parse_string", "", ""}, // app input's EVENTS_JSON
	}
	got := make([dynamic]Parse_Site, context.temp_allocator)
	for f in files do append(&got, ..scan_source(f[0], f[1]))
	for g in got {
		if g.limit == "ALIASED" do testing.expectf(t, false, "%s: %s: import core:encoding/json as json (or use jg), so the scan can see its calls", g.file, g.call)
		else do testing.expectf(t, g.limit != "UNGUARDED", "%s %s: %s with no guard before it: use jg (src/jsonguard)", g.file, g.proc_name, g.call)
	}
	used := make([]bool, len(got), context.temp_allocator)
	for w in WANT {
		found := false
		for g, i in got do if !used[i] && g == w {used[i], found = true, true; break}
		testing.expectf(t, found, "expected site gone or changed: %v", w)
	}
	for g, i in got do testing.expectf(t, used[i], "new JSON parse site, not in the list: %v (add it, with its limit)", g)
}
