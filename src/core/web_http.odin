package core

// Web access's listener (web.odin; docs/PROTOCOL.md §5b): a small hand-written HTTP/1.1 server.
// One request per connection (Connection: close), GET and POST only, at most WEB_HEAD_MAX bytes of
// request line and headers and WEB_BODY_MAX of body, all within WEB_READ_MS; at most
// WEB_CONNS_MAX connections at once before an upgrade, WEB_RELAYS_MAX WebSockets.
//
//   GET  /                the web client (web/dist/index.html)
//   GET  /assets/<file>   its files (web/dist/assets/)
//   GET  /api/whoami      200 {"paired":true,"name","core","version"} (the cookie renewed), or 401
//   POST /api/pair        {"code","name"} -> 200 and the cookie, or 403
//   POST /api/unpair      the caller's own token forgotten (its link closes)
//   GET  /ws              the WebSocket: each binary message exactly one framed-wire frame
//
// Every POST and the upgrade need an Origin whose host:port is the Host header (no CORS headers at
// all), so another site's page cannot drive them. The upgrade and whoami need the cookie.
//
// The relay (one thread per WebSocket): the browser's messages go to one end of a socketpair as
// frames, the other end is the window's link over the socket transport (window_sock.odin's
// web_arrived), so its caps, backlog and flow control are the window's. Anything that is not
// exactly one frame per binary message, a text message, a fragment, an unmasked frame or a
// message over WEB_MSG_MAX closes the link. The relay pings every WEB_PING and closes a browser
// silent for WEB_SILENT.

import "base:runtime"
import "core:c"
import "core:crypto/legacy/sha1"
import "core:encoding/base64"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:sys/posix"
import "core:thread"
import "core:time"

import cw "../corewire"
import jg "../jsonguard"

WEB_HEAD_MAX :: 8 * 1024
WEB_BODY_MAX :: 4 * 1024
WEB_TARGET_MAX :: 2048
WEB_READ_MS :: 10_000
WEB_CONNS_MAX :: 16
WEB_RELAYS_MAX :: 4
WEB_MSG_MAX :: cw.HEADER_SIZE + cw.MAX_PAYLOAD // a browser's message: one frame at most
WEB_PING :: 30 * time.Second
WEB_SILENT :: 90 * time.Second
WEB_COOKIE :: "deckhand_web"
WS_GUID :: "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

// ---- the request (pure) ----

Http_Request :: struct {
	method, target:       string,
	http11:               bool,
	host, origin, cookie: string,
	content_length:       int, // -1: none
	upgrade, connection:  string,
	ws_key, ws_version:   string,
	chunked:              bool, // a Transfer-Encoding header (refused)
}

Http_Parse :: enum u8 {
	Need_More,
	Ok,
	Bad, // 400
	Too_Large, // 431
}

// The request line and headers in buf (strings point into it). used: their bytes with the blank
// line. Duplicate Host, Origin, Cookie or Content-Length, folded lines, control characters, a
// target that is not origin-form, and anything past WEB_HEAD_MAX are refused.
http_parse :: proc(buf: []u8) -> (r: Http_Request, used: int, st: Http_Parse) {
	text := string(buf)
	end := strings.index(text, "\r\n\r\n")
	if end < 0 {
		if len(buf) > WEB_HEAD_MAX do return {}, 0, .Too_Large
		return {}, 0, .Need_More
	}
	if end + 4 > WEB_HEAD_MAX do return {}, 0, .Too_Large
	r.content_length = -1
	lines := strings.split(text[:end], "\r\n", context.temp_allocator)
	// the request line: METHOD SP origin-form SP HTTP/1.x
	parts := strings.split(lines[0], " ", context.temp_allocator)
	if len(parts) != 3 do return {}, 0, .Bad
	r.method, r.target = parts[0], parts[1]
	switch parts[2] {
	case "HTTP/1.1": r.http11 = true
	case "HTTP/1.0":
	case: return {}, 0, .Bad
	}
	if len(r.method) == 0 || len(r.method) > 16 do return {}, 0, .Bad
	for ch in transmute([]u8)r.method do if ch < 'A' || ch > 'Z' do return {}, 0, .Bad
	if len(r.target) == 0 || len(r.target) > WEB_TARGET_MAX || r.target[0] != '/' do return {}, 0, .Bad
	for ch in transmute([]u8)r.target do if ch <= 0x20 || ch >= 0x7f do return {}, 0, .Bad
	seen: bit_set[0 ..< 4]
	for line in lines[1:] {
		if len(line) == 0 || line[0] == ' ' || line[0] == '\t' do return {}, 0, .Bad // obsolete folding
		colon := strings.index_byte(line, ':')
		if colon <= 0 do return {}, 0, .Bad
		name := line[:colon]
		for ch in transmute([]u8)name do if ch <= 0x20 || ch >= 0x7f do return {}, 0, .Bad
		value := strings.trim(line[colon + 1:], " \t")
		for ch in transmute([]u8)value do if (ch < 0x20 && ch != '\t') || ch == 0x7f do return {}, 0, .Bad
		one :: proc(seen: ^bit_set[0 ..< 4], i: int) -> bool {
			if i in seen^ do return false
			seen^ += {i}
			return true
		}
		switch {
		case strings.equal_fold(name, "host"):
			if !one(&seen, 0) do return {}, 0, .Bad
			r.host = value
		case strings.equal_fold(name, "origin"):
			if !one(&seen, 1) do return {}, 0, .Bad
			r.origin = value
		case strings.equal_fold(name, "cookie"):
			if !one(&seen, 2) do return {}, 0, .Bad
			r.cookie = value
		case strings.equal_fold(name, "content-length"):
			if !one(&seen, 3) do return {}, 0, .Bad
			if len(value) == 0 || len(value) > 9 do return {}, 0, .Bad
			n := 0
			for ch in transmute([]u8)value {
				if ch < '0' || ch > '9' do return {}, 0, .Bad
				n = n * 10 + int(ch - '0')
			}
			r.content_length = n
		case strings.equal_fold(name, "transfer-encoding"):
			r.chunked = true
		case strings.equal_fold(name, "upgrade"):
			r.upgrade = value
		case strings.equal_fold(name, "connection"):
			r.connection = value
		case strings.equal_fold(name, "sec-websocket-key"):
			r.ws_key = value
		case strings.equal_fold(name, "sec-websocket-version"):
			r.ws_version = value
		}
	}
	if r.http11 && r.host == "" do return {}, 0, .Bad
	return r, end + 4, .Ok
}

// The path of a target, its query dropped.
http_path :: proc(target: string) -> string {
	if q := strings.index_byte(target, '?'); q >= 0 do return target[:q]
	return target
}

// The Origin names this server as the Host header does: scheme http or https, then exactly the
// Host's host:port (case aside). A missing Origin, "null" or any other site's is refused.
web_origin_ok :: proc(origin, host: string) -> bool {
	if host == "" || origin == "" do return false
	rest: string
	switch {
	case strings.has_prefix(origin, "http://"):  rest = origin[len("http://"):]
	case strings.has_prefix(origin, "https://"): rest = origin[len("https://"):]
	case: return false
	}
	return strings.equal_fold(rest, host)
}

// A Host header fit to repeat in a header (the CSP's connect-src): host characters only.
web_host_safe :: proc(host: string) -> bool {
	if host == "" || len(host) > 255 do return false
	for ch in transmute([]u8)host {
		switch ch {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '.', '-', ':', '[', ']':
		case: return false
		}
	}
	return true
}

// The deckhand_web cookie's value in a Cookie header ("" = none).
web_cookie_value :: proc(header: string) -> string {
	rest := header
	for part in strings.split_iterator(&rest, ";") {
		p := strings.trim_space(part)
		if strings.has_prefix(p, WEB_COOKIE + "=") do return p[len(WEB_COOKIE) + 1:]
	}
	return ""
}

// Whether a comma-separated header holds token (case aside).
http_has_token :: proc(header, token: string) -> bool {
	rest := header
	for part in strings.split_iterator(&rest, ",") do if strings.equal_fold(strings.trim_space(part), token) do return true
	return false
}

// The upgrade's own headers are right (Origin and the cookie are checked apart). "" = yes.
ws_upgrade_problem :: proc(r: Http_Request) -> string {
	if r.method != "GET" || !r.http11 do return "the upgrade is a GET over HTTP/1.1"
	if !http_has_token(r.upgrade, "websocket") || !http_has_token(r.connection, "upgrade") do return "not a WebSocket upgrade"
	if r.ws_version != "13" do return "Sec-WebSocket-Version 13 only"
	raw, err := base64.decode(r.ws_key, allocator = context.temp_allocator)
	if err != nil || len(raw) != 16 do return "a bad Sec-WebSocket-Key"
	return ""
}

// Sec-WebSocket-Accept for a key (temp).
ws_accept_key :: proc(key: string) -> string {
	ctx: sha1.Context
	sha1.init(&ctx)
	sha1.update(&ctx, transmute([]u8)key)
	sha1.update(&ctx, transmute([]u8)string(WS_GUID))
	sum: [sha1.DIGEST_SIZE]u8
	sha1.final(&ctx, sum[:])
	return base64.encode(sum[:], allocator = context.temp_allocator)
}

// ---- WebSocket frames (pure) ----

Ws_Op :: enum u8 {
	Continuation = 0x0,
	Text         = 0x1,
	Binary       = 0x2,
	Close        = 0x8,
	Ping         = 0x9,
	Pong         = 0xA,
}

Ws_Frame :: struct {
	op:      Ws_Op,
	payload: []u8, // unmasked in place, in the input
}

Ws_Parse :: enum u8 {
	Need_More,
	Ok,
	Bad, // the link closes
}

// One frame from a browser at the start of buf, unmasked in place. Refused: a frame not masked,
// RSV bits, an unknown opcode, a fragment (FIN clear, or a continuation), a control frame over
// 125 bytes, a length not in its shortest form, and a message over max.
ws_parse :: proc(buf: []u8, max: int) -> (f: Ws_Frame, used: int, st: Ws_Parse, why: string) {
	if len(buf) < 2 do return {}, 0, .Need_More, ""
	b0, b1 := buf[0], buf[1]
	fin := b0 & 0x80 != 0
	if b0 & 0x70 != 0 do return {}, 0, .Bad, "RSV bits set"
	op := b0 & 0x0f
	switch op {
	case 0x0, 0x1, 0x2, 0x8, 0x9, 0xA:
	case: return {}, 0, .Bad, "unknown opcode"
	}
	if !fin || op == 0x0 do return {}, 0, .Bad, "fragmented messages are not taken"
	if b1 & 0x80 == 0 do return {}, 0, .Bad, "a browser's frame must be masked"
	n := u64(b1 & 0x7f)
	at := 2
	switch n {
	case 126:
		if len(buf) < 4 do return {}, 0, .Need_More, ""
		n = u64(endian.unchecked_get_u16be(buf[2:]))
		if n < 126 do return {}, 0, .Bad, "length not in its shortest form"
		at = 4
	case 127:
		if len(buf) < 10 do return {}, 0, .Need_More, ""
		n = endian.unchecked_get_u64be(buf[2:])
		if n >> 63 != 0 do return {}, 0, .Bad, "length too large"
		if n <= 0xffff do return {}, 0, .Bad, "length not in its shortest form"
		at = 10
	}
	if op >= 0x8 && n > 125 do return {}, 0, .Bad, "a control frame over 125 bytes"
	if n > u64(max) do return {}, 0, .Bad, "a message over the limit"
	if len(buf) < at + 4 do return {}, 0, .Need_More, ""
	mask := buf[at:at + 4]
	at += 4
	if u64(len(buf) - at) < n do return {}, 0, .Need_More, ""
	p := buf[at:at + int(n)]
	for i in 0 ..< len(p) do p[i] ~= mask[i & 3]
	return {op = Ws_Op(op), payload = p}, at + int(n), .Ok, ""
}

// A server frame's header (never masked): its bytes in out, how many.
ws_header :: proc(op: Ws_Op, n: int, out: ^[10]u8) -> int {
	out[0] = 0x80 | u8(op)
	switch {
	case n < 126:
		out[1] = u8(n)
		return 2
	case n <= 0xffff:
		out[1] = 126
		endian.unchecked_put_u16be(out[2:], u16(n))
		return 4
	}
	out[1] = 127
	endian.unchecked_put_u64be(out[2:], u64(n))
	return 10
}

// A browser's binary message is exactly one framed-wire frame. "" = yes.
ws_frame_problem :: proc(msg: []u8) -> string {
	h, ok := cw.parse_header(msg)
	if !ok do return "shorter than a frame header"
	if int(h.len) > cw.MAX_PAYLOAD do return "over the frame limit"
	if len(msg) != cw.HEADER_SIZE + int(h.len) do return "not exactly one frame"
	return ""
}

// ---- the listener ----

// A TCP listener on addr (main thread). fd -1: why.
web_tcp_listen :: proc(addr: string) -> (fd: Sock_Fd, why: string) {
	a, ok := web_addr_parse(addr)
	if !ok do return -1, "not an address and a port"
	fd = posix.socket(a.v6 ? .INET6 : .INET, .STREAM)
	if fd < 0 do return -1, fmt.tprintf("socket: %v", posix.errno())
	posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	one: c.int = 1
	posix.setsockopt(fd, posix.SOL_SOCKET, .REUSEADDR, &one, size_of(one))
	res: posix.result
	if a.v6 {
		sa: posix.sockaddr_in6
		when ODIN_OS == .Darwin do sa.sin6_len = size_of(sa)
		sa.sin6_family = .INET6
		sa.sin6_port = posix.in_port_t(a.port)
		copy(sa.sin6_addr.s6_addr[:], a.ip[:])
		res = posix.bind(fd, (^posix.sockaddr)(&sa), size_of(sa))
	} else {
		sa: posix.sockaddr_in
		when ODIN_OS == .Darwin do sa.sin_len = size_of(sa)
		sa.sin_family = .INET
		sa.sin_port = posix.in_port_t(a.port)
		copy((^[4]u8)(&sa.sin_addr)[:], a.ip[:4])
		res = posix.bind(fd, (^posix.sockaddr)(&sa), size_of(sa))
	}
	if res != .OK || posix.listen(fd, 32) != .OK {
		e := posix.errno()
		posix.close(fd)
		if e == .EADDRINUSE do return -1, "the port is in use"
		if e == .EADDRNOTAVAIL do return -1, "this machine has no such address"
		if e == .EACCES do return -1, "not allowed to listen on that port"
		return -1, fmt.tprintf("cannot listen (%v)", e)
	}
	posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) | posix.O_NONBLOCK)
	return fd, ""
}

@(private = "file")
web_tcp_opts :: proc(fd: Sock_Fd) {
	posix.fcntl(fd, .SETFD, posix.FD_CLOEXEC)
	posix.fcntl(fd, .SETFL, posix.fcntl(fd, .GETFL) &~ i32(posix.O_NONBLOCK))
	when ODIN_OS == .Darwin {
		one: c.int = 1
		SO_NOSIGPIPE :: 0x1022
		posix.setsockopt(fd, posix.SOL_SOCKET, posix.Sock_Option(SO_NOSIGPIPE), &one, size_of(one))
	}
	tv := posix.timeval{tv_sec = 30} // a browser that stops reading: the relay's writes give up
	posix.setsockopt(fd, posix.SOL_SOCKET, .SNDTIMEO, &tv, size_of(tv))
}

// The accept thread: a connection thread each, while the listener's epoch holds.
web_accept_loop :: proc(fd: Sock_Fd, epoch: u64) {
	for sync.atomic_load(&web.epoch) == epoch {
		pfd := posix.pollfd{fd = fd, events = {.IN}}
		if posix.poll(&pfd, 1, 200) <= 0 do continue
		cfd := posix.accept(fd, nil, nil)
		if cfd < 0 do continue
		web_tcp_opts(cfd)
		if sync.atomic_load(&web.conns) >= WEB_CONNS_MAX {
			posix.close(cfd) // too many at once: the browser tries again
			continue
		}
		sync.atomic_add(&web.conns, 1)
		if thread.create_and_start_with_poly_data2(cfd, epoch, web_conn, self_cleanup = true) == nil {
			sync.atomic_sub(&web.conns, 1)
			posix.close(cfd)
		}
	}
}

// One connection: one request. An upgrade becomes the relay.
@(private = "file")
web_conn :: proc(fd: Sock_Fd, epoch: u64) {
	context.allocator = runtime.heap_allocator()
	relayed := false
	defer {
		if !relayed do sync.atomic_sub(&web.conns, 1)
		posix.close(fd)
		free_all(context.temp_allocator)
	}
	buf := make([dynamic]u8, 0, 1024, context.temp_allocator)
	deadline := time.tick_add(time.tick_now(), WEB_READ_MS * time.Millisecond)
	req: Http_Request
	used: int
	for {
		st: Http_Parse
		req, used, st = http_parse(buf[:])
		if st == .Ok do break
		if st == .Bad {
			web_send(fd, 400, "text/plain; charset=utf-8", "bad request")
			return
		}
		if st == .Too_Large {
			web_send(fd, 431, "text/plain; charset=utf-8", "request headers too large")
			return
		}
		if !web_read_more(fd, &buf, deadline, WEB_HEAD_MAX + 1) do return
	}
	if req.method != "GET" && req.method != "POST" {
		web_send(fd, 405, "text/plain; charset=utf-8", "GET and POST only")
		return
	}
	if req.chunked {
		web_send(fd, 400, "text/plain; charset=utf-8", "no Transfer-Encoding")
		return
	}
	body: []u8
	if req.method == "POST" {
		if req.content_length < 0 || req.content_length > WEB_BODY_MAX {
			web_send(fd, req.content_length < 0 ? 411 : 413, "text/plain; charset=utf-8", "a short body with Content-Length")
			return
		}
		for len(buf) - used < req.content_length do if !web_read_more(fd, &buf, deadline, used + req.content_length) do return
		body = buf[used:used + req.content_length]
	} else if req.content_length > 0 {
		web_send(fd, 400, "text/plain; charset=utf-8", "a GET has no body")
		return
	}
	path := http_path(req.target)
	now := time.to_unix_seconds(time.now())
	switch path {
	case "/api/whoami":
		if req.method != "GET" do break
		tok := web_cookie_value(req.cookie)
		_, name, ok := web_token_device(tok, now)
		if !ok {
			web_send(fd, 401, "application/json", `{"paired":false}`)
			return
		}
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, `{"paired":true,"name":`)
		json_quote(&b, name)
		strings.write_string(&b, `,"core":`)
		json_quote(&b, window_door_core_id())
		strings.write_string(&b, `,"version":`)
		json_quote(&b, core_version())
		strings.write_byte(&b, '}')
		web_send(fd, 200, "application/json", strings.to_string(b), cookie = tok) // renewed: 60 days from its last use
		return
	case "/api/pair":
		if req.method != "POST" do break
		if !web_origin_ok(req.origin, req.host) {
			web_send(fd, 403, "application/json", `{"paired":false,"error":"wrong origin"}`)
			return
		}
		code, name := web_pair_body(string(body))
		a, tok := web_pair_try(code, name, now)
		switch a {
		case .Paired:
			web_send(fd, 200, "application/json", `{"paired":true}`, cookie = tok)
		case .Full:
			web_send(fd, 403, "application/json", `{"paired":false,"error":"too many paired browsers: revoke one in Settings first"}`)
		case .Wrong, .None:
			web_send(fd, 403, "application/json", `{"paired":false,"error":"wrong or expired code"}`)
		}
		return
	case "/api/unpair":
		if req.method != "POST" do break
		if !web_origin_ok(req.origin, req.host) {
			web_send(fd, 403, "application/json", `{"error":"wrong origin"}`)
			return
		}
		web_token_forget(web_cookie_value(req.cookie))
		web_send(fd, 200, "application/json", `{"paired":false}`, clear_cookie = true)
		return
	case "/ws":
		if req.method != "GET" do break
		if why := ws_upgrade_problem(req); why != "" {
			web_send(fd, 400, "text/plain; charset=utf-8", why)
			return
		}
		if !web_origin_ok(req.origin, req.host) {
			web_send(fd, 403, "text/plain; charset=utf-8", "wrong origin")
			return
		}
		id, name, ok := web_token_device(web_cookie_value(req.cookie), now)
		if !ok {
			web_send(fd, 401, "text/plain; charset=utf-8", "not paired")
			return
		}
		if sync.atomic_load(&web.relays) >= WEB_RELAYS_MAX {
			web_send(fd, 503, "text/plain; charset=utf-8", "too many links")
			return
		}
		relayed = true
		sync.atomic_sub(&web.conns, 1)
		sync.atomic_add(&web.relays, 1)
		defer sync.atomic_sub(&web.relays, 1)
		web_relay(fd, epoch, req.ws_key, buf[used:], id, name)
		return
	case:
		if req.method != "GET" do break
		if web_asset_send(fd, path, req.host) do return
		web_send(fd, 404, "text/plain; charset=utf-8", "not found")
		return
	}
	web_send(fd, 405, "text/plain; charset=utf-8", "method not allowed here")
}

// {"code","name"} (strings; "" when missing).
@(private = "file")
web_pair_body :: proc(body: string) -> (code, name: string) {
	v, err := jg.parse_string(body, .JSON, true, context.temp_allocator)
	if err != nil do return
	o, _ := v.(json.Object)
	code, _ = o["code"].(json.String)
	name, _ = o["name"].(json.String)
	return
}

// Reads more into buf until deadline, never past max bytes. False: closed, timed out or full.
@(private = "file")
web_read_more :: proc(fd: Sock_Fd, buf: ^[dynamic]u8, deadline: time.Tick, max: int) -> bool {
	if len(buf) >= max do return false
	left := int(time.duration_milliseconds(time.tick_diff(time.tick_now(), deadline)))
	if left <= 0 || !sock_wait_readable(fd, left) do return false
	chunk: [4096]u8
	n := sock_read(fd, chunk[:min(len(chunk), max - len(buf))])
	if n <= 0 do return false
	append(buf, ..chunk[:n])
	return true
}

WEB_CSP :: "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; font-src 'self'; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'"

// The response, Connection: close. cookie: Set-Cookie with this token; clear_cookie: an expired one.
web_send :: proc(fd: Sock_Fd, status: int, ctype: string, body: string, cookie := "", clear_cookie := false, host := "", api := true) {
	reason := "OK"
	switch status {
	case 101: reason = "Switching Protocols"
	case 400: reason = "Bad Request"
	case 401: reason = "Unauthorized"
	case 403: reason = "Forbidden"
	case 404: reason = "Not Found"
	case 405: reason = "Method Not Allowed"
	case 411: reason = "Length Required"
	case 413: reason = "Content Too Large"
	case 431: reason = "Request Header Fields Too Large"
	case 503: reason = "Service Unavailable"
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %d\r\n", status, reason, ctype, len(body))
	web_security_headers(&b, host)
	strings.write_string(&b, api ? "Cache-Control: no-store\r\n" : "Cache-Control: no-cache\r\n")
	if cookie != "" do fmt.sbprintf(&b, "Set-Cookie: %s=%s; HttpOnly; SameSite=Strict; Path=/; Max-Age=%d\r\n", WEB_COOKIE, cookie, WEB_DEVICE_IDLE_S)
	if clear_cookie do fmt.sbprintf(&b, "Set-Cookie: %s=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0\r\n", WEB_COOKIE)
	strings.write_string(&b, "Connection: close\r\n\r\n")
	strings.write_string(&b, body)
	sock_write_all(fd, b.buf[:])
}

@(private = "file")
web_security_headers :: proc(b: ^strings.Builder, host: string) {
	strings.write_string(b, "Content-Security-Policy: ")
	strings.write_string(b, WEB_CSP)
	// the WebSocket of this very host: older Safari does not count ws: as 'self'
	if web_host_safe(host) do fmt.sbprintf(b, "; connect-src 'self' ws://%s wss://%s", host, host)
	else do strings.write_string(b, "; connect-src 'self'")
	strings.write_string(b, "\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n")
}

// ---- the relay ----

@(private = "file")
web_relay :: proc(fd: Sock_Fd, epoch: u64, key: string, early: []u8, id, name: string) {
	sp: [2]posix.FD
	if posix.socketpair(.UNIX, .STREAM, .IP, &sp) != .OK {
		web_send(fd, 503, "text/plain; charset=utf-8", "no link")
		return
	}
	posix.fcntl(sp[0], .SETFD, posix.FD_CLOEXEC)
	posix.fcntl(sp[1], .SETFD, posix.FD_CLOEXEC)
	when ODIN_OS == .Darwin {
		one: c.int = 1
		SO_NOSIGPIPE :: 0x1022
		posix.setsockopt(sp[0], posix.SOL_SOCKET, posix.Sock_Option(SO_NOSIGPIPE), &one, size_of(one))
		posix.setsockopt(sp[1], posix.SOL_SOCKET, posix.Sock_Option(SO_NOSIGPIPE), &one, size_of(one))
	}
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n", ws_accept_key(key))
	if !sock_write_all(fd, b.buf[:]) {
		posix.close(sp[0])
		posix.close(sp[1])
		return
	}
	web_arrived(sp[1], id, name) // the main thread attaches it as the window's link (window_sock.odin)
	defer posix.close(sp[0])
	heap := runtime.heap_allocator()
	inb := make([dynamic]u8, heap) // from the browser
	defer delete(inb)
	append(&inb, ..early)
	outb := make([dynamic]u8, heap) // from the core
	defer delete(outb)
	chunk := make([]u8, 64 << 10, heap)
	defer delete(chunk, heap)
	last_in := time.tick_now()
	last_ping := last_in
	close_code: u16 = 1000
	loop: for sync.atomic_load(&web.epoch) == epoch {
		// what the browser sent: whole frames
		for {
			f, used, st, why := ws_parse(inb[:], WEB_MSG_MAX)
			if st == .Need_More do break
			if st == .Bad {
				log_ln("Deckhand: a browser's WebSocket frame refused:", why)
				close_code = 1002
				break loop
			}
			#partial switch f.op {
			case .Binary:
				if p := ws_frame_problem(f.payload); p != "" {
					log_ln("Deckhand: a browser's message refused:", p)
					close_code = 1003
					break loop
				}
				if !sock_write_all(sp[0], f.payload) do break loop
			case .Text:
				log_ln("Deckhand: a browser sent a text message (binary frames only)")
				close_code = 1003
				break loop
			case .Ping:
				ws_send(fd, .Pong, f.payload)
			case .Close:
				break loop
			}
			remove_range(&inb, 0, used)
		}
		// what the core sent: one message per whole frame
		for {
			h, ok := cw.parse_header(outb[:])
			if !ok do break
			if int(h.len) > cw.MAX_PAYLOAD {
				close_code = 1011
				break loop
			}
			n := cw.HEADER_SIZE + int(h.len)
			if len(outb) < n do break
			if !ws_send(fd, .Binary, outb[:n]) do break loop
			remove_range(&outb, 0, n)
		}
		if time.tick_since(last_in) >= WEB_SILENT do break loop // a browser gone without a word
		if time.tick_since(last_ping) >= WEB_PING {
			last_ping = time.tick_now()
			if !ws_send(fd, .Ping, nil) do break loop
		}
		pfd := [2]posix.pollfd{{fd = fd, events = {.IN}}, {fd = sp[0], events = {.IN}}}
		if posix.poll(&pfd[0], 2, 1000) < 0 && posix.errno() != .EINTR do break
		if pfd[0].revents != {} {
			if len(inb) > WEB_MSG_MAX + 14 do break // ws_parse refuses before this
			n := sock_read(fd, chunk)
			if n <= 0 do break
			append(&inb, ..chunk[:n])
			last_in = time.tick_now()
		}
		if pfd[1].revents != {} {
			n := sock_read(sp[0], chunk)
			if n <= 0 do break // the core let the link go
			append(&outb, ..chunk[:n])
		}
		free_all(context.temp_allocator)
	}
	// what the core still sent (a last web.taken), then the close
	for {
		h, ok := cw.parse_header(outb[:])
		if !ok || int(h.len) > cw.MAX_PAYLOAD || len(outb) < cw.HEADER_SIZE + int(h.len) do break
		n := cw.HEADER_SIZE + int(h.len)
		if !ws_send(fd, .Binary, outb[:n]) do break
		remove_range(&outb, 0, n)
	}
	cb: [2]u8
	endian.unchecked_put_u16be(cb[:], close_code)
	ws_send(fd, .Close, cb[:])
}

// One unmasked message to the browser. False: the socket failed.
@(private = "file")
ws_send :: proc(fd: Sock_Fd, op: Ws_Op, payload: []u8) -> bool {
	h: [10]u8
	n := ws_header(op, len(payload), &h)
	if !sock_write_all(fd, h[:n]) do return false
	return len(payload) == 0 || sock_write_all(fd, payload)
}
