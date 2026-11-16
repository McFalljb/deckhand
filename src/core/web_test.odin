package core

import "base:runtime"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import cw "../corewire"

@(private = "file")
req :: proc(s: string) -> (Http_Request, int, Http_Parse) {
	b := transmute([]u8)strings.clone(s, context.temp_allocator)
	return http_parse(b)
}

// The request parser: what it takes, and its limits and refusals.
@(test)
web_http_parse_limits :: proc(t: ^testing.T) {
	r, used, st := req("GET /api/whoami?x=1 HTTP/1.1\r\nHost: 1.2.3.4:7433\r\nCookie: a=b; deckhand_web=ff\r\nOrigin: http://1.2.3.4:7433\r\n\r\nrest")
	testing.expect_value(t, st, Http_Parse.Ok)
	testing.expect_value(t, used, len("GET /api/whoami?x=1 HTTP/1.1\r\nHost: 1.2.3.4:7433\r\nCookie: a=b; deckhand_web=ff\r\nOrigin: http://1.2.3.4:7433\r\n\r\n"))
	testing.expect_value(t, http_path(r.target), "/api/whoami")
	testing.expect_value(t, web_cookie_value(r.cookie), "ff")
	testing.expect_value(t, r.content_length, -1)
	_, _, st = req("GET / HTTP/1.1\r\nHost: x")
	testing.expect_value(t, st, Http_Parse.Need_More)
	big := strings.concatenate({"GET / HTTP/1.1\r\nHost: x\r\nX: ", strings.repeat("a", WEB_HEAD_MAX, context.temp_allocator)}, context.temp_allocator)
	_, _, st = req(big)
	testing.expect_value(t, st, Http_Parse.Too_Large) // no end in sight past the cap
	_, _, st = req(strings.concatenate({big, "\r\n\r\n"}, context.temp_allocator))
	testing.expect_value(t, st, Http_Parse.Too_Large)
	bad := []string {
		"GET / HTTP/1.1\r\n\r\n", // no Host
		"GET / HTTP/2\r\nHost: x\r\n\r\n",
		"GET http://x/ HTTP/1.1\r\nHost: x\r\n\r\n", // not origin-form
		"GET  / HTTP/1.1\r\nHost: x\r\n\r\n",
		"get / HTTP/1.1\r\nHost: x\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: x\r\nHost: y\r\n\r\n", // a second Host
		"GET / HTTP/1.1\r\nHost: x\r\nOrigin: a\r\nOrigin: b\r\n\r\n",
		"POST /api/unpair HTTP/1.1\r\nHost: x\r\nX-Deckhand-Key: a\r\nx-deckhand-key: b\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: x\r\nX: a\r\n folded\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: x\r\nNoColon\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: x\x01\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: -1\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\n",
		"GET / HTTP/1.1\r\nHost: x\r\nContent-Length: 9999999999\r\n\r\n",
		"GET /\x7f HTTP/1.1\r\nHost: x\r\n\r\n",
	}
	for b in bad {
		_, _, s := req(b)
		testing.expectf(t, s == .Bad, "refused: %q (%v)", b, s)
	}
	r, _, st = req("POST /api/pair HTTP/1.1\r\nHost: x\r\ncontent-length: 12\r\nTransfer-Encoding: chunked\r\n\r\n")
	testing.expect(t, st == .Ok && r.content_length == 12 && r.chunked, "headers are case-insensitive; chunked is seen (and refused by the server)")
}

// Origin must name this very host:port; no Origin, null or another site's is refused.
@(test)
web_origin_host :: proc(t: ^testing.T) {
	testing.expect(t, web_origin_ok("http://100.1.2.3:7433", "100.1.2.3:7433"))
	testing.expect(t, web_origin_ok("https://Box.example:443", "box.example:443"))
	testing.expect(t, !web_origin_ok("", "x:1"))
	testing.expect(t, !web_origin_ok("null", "x:1"))
	testing.expect(t, !web_origin_ok("http://evil.example", "x:1"))
	testing.expect(t, !web_origin_ok("http://x:1.evil", "x:1"))
	testing.expect(t, !web_origin_ok("ws://x:1", "x:1"))
	testing.expect(t, !web_origin_ok("http://x:1", ""))
	testing.expect(t, web_host_safe("[fd7a::1]:7433") && !web_host_safe("x; script-src *") && !web_host_safe(""))
}

@(private = "file")
ws_frame :: proc(op: u8, payload: []u8, fin := true, masked := true, rsv: u8 = 0) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	append(&out, (fin ? 0x80 : 0) | rsv | op)
	n := len(payload)
	m: u8 = masked ? 0x80 : 0
	switch {
	case n < 126: append(&out, m | u8(n))
	case n <= 0xffff:
		append(&out, m | 126, 0, 0)
		endian.unchecked_put_u16be(out[len(out) - 2:], u16(n))
	case:
		append(&out, m | 127, 0, 0, 0, 0, 0, 0, 0, 0)
		endian.unchecked_put_u64be(out[len(out) - 8:], u64(n))
	}
	mask := [4]u8{1, 2, 3, 4}
	if masked do append(&out, ..mask[:])
	for b, i in payload do append(&out, masked ? b ~ mask[i & 3] : b)
	return out[:]
}

// WebSocket frames: masking, fragmentation and length forms, the size limit.
@(test)
web_ws_frames :: proc(t: ^testing.T) {
	msg := transmute([]u8)strings.clone("hello", context.temp_allocator)
	buf := ws_frame(0x2, msg)
	f, used, st, _ := ws_parse(buf[:len(buf) - 1], 100)
	testing.expect_value(t, st, Ws_Parse.Need_More)
	f, used, st, _ = ws_parse(buf, 100)
	testing.expect(t, st == .Ok && f.op == .Binary && string(f.payload) == "hello" && used == len(buf), "a masked binary frame, unmasked")
	long := make([]u8, 300, context.temp_allocator)
	f, used, st, _ = ws_parse(ws_frame(0x2, long), 1000)
	testing.expect(t, st == .Ok && len(f.payload) == 300, "the 16-bit length")
	_, _, st, _ = ws_parse(ws_frame(0x2, long), 299)
	testing.expect_value(t, st, Ws_Parse.Bad) // over the limit: refused before it is read
	bads := [][]u8 {
		ws_frame(0x2, msg, masked = false),
		ws_frame(0x2, msg, fin = false), // a fragment
		ws_frame(0x0, msg), // a continuation
		ws_frame(0x2, msg, rsv = 0x40), // a compressed frame (no extension was agreed)
		ws_frame(0x3, msg), // a reserved opcode
		ws_frame(0x9, long), // a ping over 125 bytes
	}
	for b in bads {
		_, _, s, _ := ws_parse(b, 1000)
		testing.expectf(t, s == .Bad, "refused: % x", b[:2])
	}
	short := []u8{0x82, 0x80 | 126, 0, 5, 1, 2, 3, 4, 0, 0, 0, 0, 0} // 5 in the 16-bit form
	_, _, st, _ = ws_parse(short, 100)
	testing.expect_value(t, st, Ws_Parse.Bad)
	h: [10]u8
	testing.expect_value(t, ws_header(.Binary, 70000, &h), 10)
	testing.expect_value(t, h[1], u8(127))
	testing.expect_value(t, ws_accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") // RFC 6455's example
	// a browser's message: exactly one framed-wire frame
	one := []u8{0, 0, 0, 0, 1, 2, 0, 0, 0, '{', '}'}
	testing.expect_value(t, ws_frame_problem(one), "")
	testing.expect(t, ws_frame_problem(one[:10]) != "", "short")
	two := make([]u8, 22, context.temp_allocator)
	copy(two, one)
	copy(two[11:], one)
	testing.expect(t, ws_frame_problem(two) != "", "two frames")
	testing.expect(t, ws_frame_problem(one[:5]) != "", "no header")
}

when TEST_HOOKS {
// Pairing: single use, two minutes, void after five wrong tries; tokens checked and forgotten.
@(test)
web_pairing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	web_reset_for_test()
	defer web_reset_for_test()
	now: i64 = 1_800_000_000
	a, tok, _ := web_pair_try("ABCDEFGH", "x", now)
	testing.expect_value(t, a, Web_Pair_Answer.None) // no code open
	code, until := web_code_open(now)
	testing.expect_value(t, until, now + 120)
	testing.expect_value(t, len(code), WEB_CODE_LEN)
	for ch in transmute([]u8)code do testing.expect(t, strings.index_byte(WEB_CODE_ALPHABET, ch) >= 0)
	// typed with a dash, in lower case: the same code
	a, tok, _ = web_pair_try(strings.to_lower(web_code_shown(code), context.temp_allocator), "  My phone \x1b[31m ", now + 10)
	testing.expect_value(t, a, Web_Pair_Answer.Paired)
	testing.expect(t, hex64_ok(tok), "a 256-bit token, hex")
	a, _, _ = web_pair_try(code, "again", now + 11)
	testing.expect_value(t, a, Web_Pair_Answer.None) // single use
	id, name, ok := web_token_device(tok, now + 20)
	testing.expect(t, ok && len(id) == 12 && !strings.contains(name, "\x1b"), "the token names the browser (its name cleaned)")
	_, _, ok = web_token_device(strings.repeat("0", 64, context.temp_allocator), now)
	testing.expect(t, !ok, "an unknown token")
	_, _, ok = web_token_device("not hex", now)
	testing.expect(t, !ok, "not a token")
	// expiry: two minutes
	code, _ = web_code_open(now)
	a, _, _ = web_pair_try(code, "late", now + 121)
	testing.expect_value(t, a, Web_Pair_Answer.None)
	// five wrong tries void it, even for the right code after
	code, _ = web_code_open(now)
	wrong := code[0] == 'A' ? "BBBBBBBB" : "AAAAAAAA"
	for i in 0 ..< WEB_CODE_TRIES {
		a, _, _ = web_pair_try(wrong, "x", now + 1)
		testing.expectf(t, a == .Wrong, "try %d", i)
	}
	a, _, _ = web_pair_try(code, "x", now + 2)
	testing.expect_value(t, a, Web_Pair_Answer.None)
	// a token unused for 60 days no longer works
	_, _, ok = web_token_device(tok, now + WEB_DEVICE_IDLE_S + 100)
	testing.expect(t, !ok, "expired")
	// unpair forgets it, and its link is asked to close
	testing.expect(t, web_token_forget(tok) && !web_token_forget(tok), "forgotten once")
	testing.expect_value(t, web_device_count_for_test(), 0)
	testing.expect_value(t, web_code_normal("ABCD-EFG"), "")
	testing.expect_value(t, web_code_normal("ABCD-EFGI"), "") // I is not in the alphabet
	testing.expect_value(t, web_code_normal("abcd efgh"), "ABCDEFGH")
	// the file holds hashes, never a token; it reads back
	code, _ = web_code_open(now)
	_, tok, _ = web_pair_try(code, "file", now)
	sync_text := web_devices_encode(web_devices_for_test())
	testing.expect(t, !strings.contains(sync_text, tok), "no token in the file")
	back := web_devices_decode(sync_text, context.temp_allocator)
	testing.expect(t, len(back) == 1 && back[0].name == "file" && back[0].hash == token_hash(tok), "it reads back")
	testing.expect_value(t, len(web_devices_decode(`{"devices":[{"id":"x","hash":"zz"}]}`, context.temp_allocator)), 0)
}

// A cookie is a host's, not a port's: another service on the same name gets it. So pairing also
// hands the browser a key that only its own origin's storage keeps, and the link wants both.
@(test)
web_pair_key :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	web_reset_for_test()
	defer web_reset_for_test()
	now: i64 = 1_800_000_000
	code, _ := web_code_open(now)
	a, tok, key := web_pair_try(code, "phone", now)
	testing.expect_value(t, a, Web_Pair_Answer.Paired)
	testing.expect(t, hex64_ok(key) && key != tok, "a second 256-bit secret")
	id, _, ok := web_token_device(tok, now)
	testing.expect(t, ok, "paired")
	testing.expect(t, web_key_ok(id, key), "its key")
	testing.expect(t, !web_key_ok(id, tok), "the token is not the key")
	testing.expect(t, !web_key_ok(id, strings.repeat("0", 64, context.temp_allocator)), "a wrong key")
	testing.expect(t, !web_key_ok(id, ""), "no key")
	code, _ = web_code_open(now)
	_, tok2, key2 := web_pair_try(code, "laptop", now)
	id2, _, _ := web_token_device(tok2, now)
	testing.expect(t, !web_key_ok(id, key2) && !web_key_ok(id2, key), "another browser's key")
	// the file holds its hash, never the key; an entry without one is dropped
	text := web_devices_encode(web_devices_for_test())
	testing.expect(t, !strings.contains(text, key) && !strings.contains(text, tok), "no secret in the file")
	back := web_devices_decode(text, context.temp_allocator)
	testing.expect(t, len(back) == 2 && back[0].key_hash == token_hash(key), "the key's hash reads back")
	h := hex32(token_hash("x"))
	old := fmt.tprintf(`{{"devices":[{{"id":"aabbccddeeff","hash":"%s","paired":1,"last_seen":1}}]}}`, h)
	testing.expect_value(t, len(web_devices_decode(old, context.temp_allocator)), 0)
}

// Item 3 of round 1: a connection checked on its thread may reach the main thread after its
// browser was revoked or expired; the attach checks again.
@(test)
web_device_live_check :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	web_reset_for_test()
	defer web_reset_for_test()
	now: i64 = 1_800_000_000
	code, _ := web_code_open(now)
	_, tok, _ := web_pair_try(code, "phone", now)
	id, _, _ := web_token_device(tok, now)
	testing.expect(t, web_device_live(id, now + 5), "still paired")
	testing.expect(t, !web_device_live(id, now + WEB_DEVICE_IDLE_S + 100), "expired")
	testing.expect(t, !web_device_live("", now), "no id")
	testing.expect(t, web_token_forget(tok), "revoked")
	testing.expect(t, !web_device_live(id, now + 5), "revoked: not attached")
}

// Round 2: the recheck and the attach are one step for a browser's own unpair (its connection's
// thread): web_device_hold keeps the devices as they are until web_device_release.
@(test)
web_device_hold_blocks_unpair :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	web_reset_for_test()
	defer web_reset_for_test()
	now := time.to_unix_seconds(time.now())
	code, _ := web_code_open(now)
	_, tok, _ := web_pair_try(code, "phone", now)
	id, _, _ := web_token_device(tok, now)
	Unpair :: struct {
		tok:  string,
		done: bool,
	}
	u := Unpair{tok = strings.clone(tok)}
	defer delete(u.tok)
	testing.expect(t, web_device_hold(id, now), "live, and held")
	th := thread.create_and_start_with_data(&u, proc(p: rawptr) {
		u := (^Unpair)(p)
		web_token_forget(u.tok)
		sync.atomic_store(&u.done, true)
	})
	time.sleep(100 * time.Millisecond)
	testing.expect(t, !sync.atomic_load(&u.done), "the unpair waits for the attach")
	web_device_release()
	thread.join(th)
	thread.destroy(th)
	testing.expect(t, sync.atomic_load(&u.done), "then it runs")
	testing.expect(t, !web_device_hold(id, now), "gone")
	web_device_release()
}
} // when TEST_HOOKS

@(test)
web_listen_address_parse :: proc(t: ^testing.T) {
	for good in ([]string{"0.0.0.0:7433", "127.0.0.1:1", "100.101.102.103:65535", "[::]:7433", "[fd7a:115c::1]:80"}) {
		_, ok := web_addr_parse(good)
		testing.expectf(t, ok, "%s", good)
	}
	for bad in ([]string{"", "7433", ":7433", "0.0.0.0", "0.0.0.0:0", "0.0.0.0:65536", "::1:80", "[::1]", "host.example:80", "1.2.3.4:80x", "[::]:"}) {
		_, ok := web_addr_parse(bad)
		testing.expectf(t, !ok, "%q refused", bad)
	}
}

// A paired browser is the user with a hub's limits: no User_Here but three view-state ones, no
// control token, nothing of web access itself; the user at this Mac is unaffected.
@(test)
web_caller_gate :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	inbox_drain()
	state = State{}
	core_detach_window()
	defer {
		state = State{}
		core_detach_window()
	}
	web_caller := Caller{kind = .UI, web = true}
	refused := []Command {
		Set_Web_Access{on = false},
		Set_Web_Listen{address = "127.0.0.1:1"},
		Web_Pair{},
		Web_Devices{},
		Web_Revoke{id = "000000000000"},
		Copy_Control_Token{},
		Set_Machines_Reachable{on = true},
		Set_Remote_Machines{on = false},
		Set_Claude_Default_Flags{skip_permissions = true},
		Machine_Add{target = "x"},
		Set_Bell{},
	}
	for cmd in refused {
		testing.expectf(t, !caller_may(web_caller, cmd), "%s refused for a browser", command_type(cmd))
		testing.expectf(t, run_command(cmd, web_caller).error == "not allowed for this caller", "%s", command_type(cmd))
	}
	allowed := []Command {Show_No_Session{}, Set_Sidebar_View{}, Machine_Connect{no = 1}, New_Chat{project_id = 1}, Focus_Session{session = 1}, Close_Tab{tab_id = 1}, Cancel_Confirmation{token = "x"}, Set_Theme{}}
	for cmd in allowed do testing.expectf(t, caller_may(web_caller, cmd), "%s allowed for a browser", command_type(cmd))
	for cmd in refused[:5] {
		testing.expectf(t, caller_may({kind = .UI}, cmd), "%s: the user at this Mac", command_type(cmd))
		testing.expectf(t, caller_may({kind = .Internal}, cmd), "%s: the terminal's (internal)", command_type(cmd))
		testing.expectf(t, !caller_may({kind = .Control}, cmd) && !caller_may({kind = .UI, hub = true}, cmd), "%s: not an agent's nor a hub's", command_type(cmd))
	}
	testing.expect(t, !web_request_ok(.Quit) && !web_request_ok(.View_Open) && !web_request_ok(.Reveal) && web_request_ok(.Term_Fit) && web_request_ok(.Open_Url), "a browser's requests")
	r := run_command(Set_Web_Access{on = true}, {kind = .UI})
	testing.expect(t, r.error == "needs_confirmation" && r.confirm_token != "" && !state.settings.web_access, "turning it on asks the user at this Mac")
	testing.expect(t, run_command(Set_Web_Access{on = true}, {kind = .Internal}).ok && state.settings.web_access, "the terminal's yes")
}

@(private = "file")
hello_frame :: proc(channel: u32, json_text: string) -> []u8 {
	out := make([dynamic]u8, context.temp_allocator)
	cw.encode(&out, channel, .Data, transmute([]u8)json_text)
	return out[:]
}

// The hello's key (web_hello_key): taken out before the hello goes on to the core, and anything
// but one hello frame on channel 0 with a key is refused.
@(test)
web_hello_key_taken :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	k := strings.repeat("ab", 32, context.temp_allocator)
	msg := hello_frame(0, fmt.tprintf(`{{"v":1,"id":"hello","type":"hello","framed":true,"peer":"web","snapshot":["vt"],"key":"%s"}}`, k))
	key, out, why := web_hello_key(msg, context.temp_allocator)
	testing.expect_value(t, why, "")
	testing.expect_value(t, key, k)
	testing.expect_value(t, ws_frame_problem(out), "")
	f, _, _ := cw.next_frame(out)
	testing.expect(t, f.channel == 0 && f.kind == u8(cw.Kind.Data), "one JSON frame")
	body := string(f.payload)
	testing.expect(t, !strings.contains(body, k) && !strings.contains(body, `"key"`), "the key stays at the door")
	v, err := json.parse_string(body, .JSON, true, context.temp_allocator)
	testing.expect(t, err == nil, "JSON")
	o, _ := v.(json.Object)
	testing.expect(t, o["type"].(json.String) == "hello" && o["peer"].(json.String) == "web" && o["framed"].(json.Boolean), "the rest kept")
	sn, _ := o["snapshot"].(json.Array)
	testing.expect(t, len(sn) == 1, "the snapshot list kept")
	for bad in ([]string{
		`{"v":1,"type":"hello"}`, // no key
		`{"v":1,"type":"state.subscribe","key":"` + "x" + `"}`, // not a hello
		`{"v":1,"type":"hello","key":7}`, // not a string
		`not json`,
		`[1,2]`,
	}) {
		_, _, why = web_hello_key(hello_frame(0, bad), context.temp_allocator)
		testing.expectf(t, why != "", "%s refused", bad)
	}
	_, _, why = web_hello_key(hello_frame(3, `{"type":"hello","key":"x"}`), context.temp_allocator)
	testing.expect(t, why != "", "not channel 0")
	_, _, why = web_hello_key(msg[:len(msg) - 1], context.temp_allocator)
	testing.expect(t, why != "", "not one whole frame")
}
