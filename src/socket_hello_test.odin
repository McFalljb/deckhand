package main

// The challenge hello and the framed hello on the control socket (docs/PROTOCOL.md §2, §5a;
// docs/plans/background-core.md §10.3 M4-B). The test thread plays the main thread and the
// client: the client's proofs are computed with the core's own helpers (hello_proof.odin), whose
// vector integrations/pi/test/unit.test.ts shares with the bridges' code.

import "base:runtime"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import "core"
import cw "corewire"

@(private = "file")
Hc :: struct {
	fd:     core.Sock_Fd,
	buf:    [dynamic]u8,
	closed: bool,
}

@(private = "file")
hs_start :: proc(t: ^testing.T) -> string {
	context.allocator = runtime.heap_allocator()
	core.inbox_drain()
	state^ = core.State{layout = {left_width = core.LEFT_WIDTH_DEFAULT, right_width = core.RIGHT_WIDTH_DEFAULT}}
	core.platform = {quit = proc() {}, set_clipboard = proc(s: string) {}}
	dir := fmt.aprintf("%s/pd-hello-%d", strings.trim_right(os.get_env("TMPDIR", context.temp_allocator), "/"), time.now()._nsec % 1_000_000_000)
	os.set_env("DECKHAND_RUNTIME_DIR", dir)
	rdir, ok := core.sock_runtime_dir(context.temp_allocator)
	testing.expect(t, ok, "runtime dir")
	testing.expect(t, core.socket_start(rdir), "socket_start")
	return dir
}

@(private = "file")
hs_stop :: proc() {
	core.socket_framed_handler = nil
	core.socket_stop(proc() {core.inbox_drain()})
}

@(private = "file")
hs_connect :: proc() -> ^Hc {
	fd, ok := core.sock_connect(core.socket_path())
	if !ok do return nil
	c := new(Hc)
	c.fd = fd
	return c
}

@(private = "file")
hs_close :: proc(c: ^Hc) {
	if c == nil do return
	core.sock_close(c.fd)
	delete(c.buf)
	free(c)
}

@(private = "file")
hs_send :: proc(c: ^Hc, line: string) {
	core.sock_write_all(c.fd, transmute([]u8)strings.concatenate({line, "\n"}, context.temp_allocator))
}

@(private = "file")
hs_recv :: proc(c: ^Hc, ms := 3000) -> string {
	start := time.tick_now()
	for {
		if i := strings.index_byte(string(c.buf[:]), '\n'); i >= 0 {
			line := strings.clone(string(c.buf[:i]), context.temp_allocator)
			remove_range(&c.buf, 0, i + 1)
			return line
		}
		if c.closed || time.tick_since(start) > time.Duration(ms) * time.Millisecond do return ""
		core.inbox_drain()
		if core.sock_wait_readable(c.fd, 5) {
			chunk: [16 * 1024]u8
			n := core.sock_read(c.fd, chunk[:])
			if n <= 0 do c.closed = true
			else do append(&c.buf, ..chunk[:n])
		}
	}
}

@(private = "file")
hs_closed :: proc(c: ^Hc) -> bool {
	for !c.closed do if hs_recv(c, 2000) == "" do break
	return c.closed
}

@(private = "file")
hs_plain :: proc(token: string, extra := "") -> (^Hc, string) {
	c := hs_connect()
	hs_send(c, fmt.tprintf(`{{"id":"h","v":1,"type":"hello","token":"%s"%s}}`, token, extra))
	return c, hs_recv(c)
}

@(private = "file")
hs_nonce :: proc() -> string {
	raw: [32]u8
	crypto.rand_bytes(raw[:])
	return core.hex32(raw)
}

// The challenge hello as a client does it: the step-1 reply, whether the core's proof verified,
// and the final reply. cnonce "": a fresh one; bad_proof: sent instead of the right proof.
@(private = "file")
Challenge :: struct {
	c:          ^Hc,
	step1, end: string,
	core_ok:    bool,
	proof:      string,
	cnonce:     string,
}

@(private = "file")
hs_challenge :: proc(token: string, cnonce := "", bad_proof := "") -> (r: Challenge) {
	key := core.token_hash(token)
	id := core.hex32(core.hello_token_id(key))
	r.cnonce = cnonce != "" ? cnonce : hs_nonce()
	r.c = hs_connect()
	hs_send(r.c, fmt.tprintf(`{{"id":"c1","v":1,"type":"hello","token_id":"%s","nonce":"%s"}}`, id, r.cnonce))
	r.step1 = hs_recv(r.c)
	if core.json_path(r.step1, "result.ok") != "true" do return
	sn := core.json_path(r.step1, "result.data.challenge")
	r.core_ok = core.hex64_equal(core.json_path(r.step1, "result.data.proof"), core.hex32(core.hello_proof(key, "core", r.cnonce, sn)))
	r.proof = bad_proof != "" ? bad_proof : core.hex32(core.hello_proof(key, "client", r.cnonce, sn))
	hs_send(r.c, fmt.tprintf(`{{"id":"c2","v":1,"type":"hello.proof","proof":"%s"}}`, r.proof))
	r.end = hs_recv(r.c)
	return
}

// An env token's hello from a client that speaks the challenge gives a challenge-only reconnect
// token: its plain hello is refused, its challenge hello works with no token on the wire, and a
// replayed or wrong proof, or an unknown token, is refused.
@(test)
socket_challenge_hello :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	hs_start(t)
	defer hs_stop()
	env := core.socket_mint_token({kind = .Panel, tab_id = 101}, context.temp_allocator, single_use = true)
	b, r := hs_plain(env, `,"challenge":true`)
	re := strings.clone(core.json_path(r, "result.data.reconnect_token"), context.temp_allocator)
	testing.expect_value(t, core.json_path(r, "result.data.reconnect_hello"), "challenge")
	p, rp := hs_plain(re)
	testing.expect_value(t, core.json_path(rp, "result.error"), "this token needs the challenge hello")
	ok := hs_challenge(re)
	testing.expect(t, ok.core_ok, "the core proves the token first")
	testing.expect_value(t, core.json_path(ok.end, "result.data.caller"), "panel")
	testing.expect_value(t, core.json_path(ok.end, "result.data.tab_id"), "101")
	rep := hs_challenge(re, cnonce = ok.cnonce, bad_proof = ok.proof) // the core's nonce is new
	testing.expect_value(t, core.json_path(rep.end, "result.error"), "the proof does not verify")
	wrong := hs_challenge(re, bad_proof = hs_nonce())
	testing.expect_value(t, core.json_path(wrong.end, "result.error"), "the proof does not verify")
	none := hs_challenge(hs_nonce())
	testing.expect_value(t, core.json_path(none.step1, "result.error"), "unknown token")
	for x in ([]^Hc{b, p, ok.c, rep.c, wrong.c, none.c}) do hs_close(x)
	free_all(context.temp_allocator)
}

// A client that does not say challenge (a kept pi session's older bridge) keeps the plain hello
// for its reconnect token, and a challenge hello with that token is unknown.
@(test)
socket_older_bridge_keeps_the_plain_hello :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	hs_start(t)
	defer hs_stop()
	env := core.socket_mint_token({kind = .Panel, tab_id = 102}, context.temp_allocator, single_use = true)
	b, r := hs_plain(env)
	re := strings.clone(core.json_path(r, "result.data.reconnect_token"), context.temp_allocator)
	testing.expect_value(t, core.json_path(r, "result.data.reconnect_hello"), "<missing>")
	c, r2 := hs_plain(re)
	testing.expect_value(t, core.json_path(r2, "result.ok"), "true")
	ch := hs_challenge(re)
	testing.expect_value(t, core.json_path(ch.step1, "result.error"), "unknown token")
	for x in ([]^Hc{b, c, ch.c}) do hs_close(x)
	free_all(context.temp_allocator)
}

// tokens.json keeps a token's hello kind: after a relaunch the challenge-only token is still
// challenge-only (known by its hash alone), and a plain one still plain.
@(test)
socket_tokens_keep_the_hello_kind :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	dir := hs_start(t)
	defer hs_stop()
	path := fmt.tprintf("%s/tokens.json", dir)
	key: [32]u8
	for i in 0 ..< 32 do key[i] = u8(i * 5 + 1)
	core.socket_tokens_enable(path, key[:])
	env := core.socket_mint_token({kind = .Panel, tab_id = 103}, context.temp_allocator, single_use = true)
	envp := core.socket_mint_token({kind = .Control, tab_id = 103}, context.temp_allocator, single_use = true)
	core.socket_tokens_bind(103, 9, {kind = .Pi})
	b, r := hs_plain(env, `,"challenge":true`)
	re := strings.clone(core.json_path(r, "result.data.reconnect_token"), context.temp_allocator)
	b2, r2 := hs_plain(envp)
	rp := strings.clone(core.json_path(r2, "result.data.reconnect_token"), context.temp_allocator)
	hs_close(b)
	hs_close(b2)
	data, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect_value(t, strings.count(string(data), `"hello":"challenge"`), 1)
	testing.expect(t, !strings.contains(string(data), re) && !strings.contains(string(data), rp), "no token on disk")
	rdir, _ := core.sock_runtime_dir(context.temp_allocator)
	core.socket_stop(proc() {core.inbox_drain()})
	testing.expect(t, core.socket_start(rdir))
	loaded, why := core.socket_tokens_enable(path, key[:])
	testing.expect(t, loaded, why)
	testing.expect(t, core.socket_tokens_adopt(9, 203))
	p, pr := hs_plain(re)
	testing.expect_value(t, core.json_path(pr, "result.error"), "this token needs the challenge hello")
	ch := hs_challenge(re)
	testing.expect(t, ch.core_ok, "proved from the hash alone")
	testing.expect_value(t, core.json_path(ch.end, "result.data.tab_id"), "203")
	q, qr := hs_plain(rp)
	testing.expect_value(t, core.json_path(qr, "result.data.caller"), "control")
	for x in ([]^Hc{p, ch.c, q}) do hs_close(x)
	core.socket_tokens_disable(true)
	free_all(context.temp_allocator)
}

@(private = "file")
hs_framed_fd: core.Sock_Fd = -1
@(private = "file")
hs_framed_caller: core.Caller
@(private = "file")
hs_framed_left: [dynamic]u8

// The framed hello: refused while nobody takes framed connections (and the env token is not used
// up); with a handler, the reply carries §5.2's fields, the connection leaves the line server, and
// the bytes the client sent right after its hello line reach the handler.
@(test)
socket_framed_hello :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	hs_start(t)
	defer hs_stop()
	tok := core.socket_mint_token({kind = .Control}, context.temp_allocator, single_use = true)
	n, rn := hs_plain(tok, `,"framed":true`)
	testing.expect_value(t, core.json_path(rn, "result.error"), "framed mode is not available in this build")
	hs_close(n)
	hs_framed_fd = -1
	clear(&hs_framed_left)
	core.socket_framed_handler = proc(fd: core.Sock_Fd, caller: core.Caller, leftover: []u8) {
		hs_framed_caller = caller
		append(&hs_framed_left, ..leftover)
		hs_framed_fd = fd // last: the test thread waits for it
	}
	c := hs_connect()
	frame := make([dynamic]u8, context.temp_allocator)
	cw.encode(&frame, 0, .Data, transmute([]u8)string(`{"type":"state.subscribe"}`))
	line := fmt.tprintf("{{\"id\":\"f\",\"v\":1,\"type\":\"hello\",\"token\":\"%s\",\"framed\":true}}\n", tok)
	both := strings.concatenate({line, string(frame[:])}, context.temp_allocator)
	core.sock_write_all(c.fd, transmute([]u8)both)
	r := hs_recv(c)
	testing.expect_value(t, core.json_path(r, "result.ok"), "true")
	testing.expect_value(t, core.json_path(r, "result.data.framed"), "true")
	testing.expect_value(t, core.json_path(r, "result.data.generation"), fmt.tprint(cw.GENERATION))
	for k in ([]string{"version", "features", "methods", "machine", "holder_wire", "snapshot"}) do testing.expect(t, core.json_path(r, fmt.tprintf("result.data.%s", k)) != "<missing>", k)
	start := time.tick_now()
	for hs_framed_fd < 0 && time.tick_since(start) < 2 * time.Second do time.sleep(time.Millisecond)
	testing.expect(t, hs_framed_fd >= 0, "the handler took the connection")
	testing.expect_value(t, hs_framed_caller.kind, core.Caller_Kind.Control)
	// the core's end as a framed transport: the frame sent with the hello, then an echo
	tr: cw.Sock_Transport
	cw.sock_open(&tr, hs_framed_fd, initial = hs_framed_left[:])
	defer cw.sock_destroy(&tr)
	f, e := cw.sock_recv(&tr)
	testing.expect(t, e == .None && string(f.payload) == `{"type":"state.subscribe"}`, "the bytes after the hello line")
	testing.expect_value(t, cw.sock_send(&tr, 7, .Data, transmute([]u8)string("out")), cw.Send_Error.None)
	cw.sock_flush(&tr)
	cl: cw.Sock_Transport
	cw.sock_open(&cl, c.fd, initial = c.buf[:])
	start = time.tick_now()
	got: cw.Frame
	ge := cw.Recv_Error.Empty
	for ge == .Empty && time.tick_since(start) < 2 * time.Second {
		got, ge = cw.sock_recv(&cl)
		cw.sock_wait(&cl, 5)
	}
	testing.expect(t, ge == .None && got.channel == 7 && string(got.payload) == "out")
	cw.sock_destroy(&cl)
	delete(c.buf)
	free(c)
	delete(hs_framed_left)
	hs_framed_left = nil
	free_all(context.temp_allocator)
}

